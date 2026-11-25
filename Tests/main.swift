import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; if !condition() { fatalError(message) } }
func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }
let september = date("2026-09-10"), october = date("2026-10-10"), november = date("2026-11-10")
var ledger = Ledger(entries: [
    LedgerEntry(kind: .contribution, title: "Sep pool", amount: 1000000, date: september),
    LedgerEntry(kind: .expense, title: "Rent", amount: 700000, date: september, category: .rent),
    LedgerEntry(kind: .expense, title: "Personal", amount: 500000, date: september, funding: .personal),
    LedgerEntry(kind: .contribution, title: "Oct pool", amount: 200000, date: october),
    LedgerEntry(kind: .expense, title: "Food", amount: 600000, date: october, category: .food)
])
check(ledger.balance(before: Ledger.start(october)) == 300000, "Positive rollover")
check(ledger.balance(before: Ledger.start(november)) == -100000, "Deficit rollover")
check(ledger.added(october) == 200000, "This month's contributions")
check(ledger.spent(september) == 700000, "Personal excluded")
check(ledger.spent(september, funding: .personal) == 500000, "Personal tracked")
check(ledger.spent(october, category: .food) == 600000, "Category spending")
ledger.entries[1].amount = 500000
check(ledger.balance(before: Ledger.start(november)) == 100000, "Backdated edits recalculate")
ledger.entries[1].deleted = true
check(ledger.balance(before: Ledger.start(november)) == 600000, "Deleted bills excluded")
ledger.entries.append(LedgerEntry(kind: .budget, title: "Food", amount: 500000, date: Ledger.start(september), category: .food))
check(ledger.budget(october, category: .food) == 500000, "Budget inherited")
ledger.entries.append(LedgerEntry(kind: .budget, title: "Food", amount: 0, date: Ledger.start(october), category: .food))
check(ledger.budget(november, category: .food) == 0, "Budget clearing inherited")
check(ledger.budget(september, category: .food) == 500000, "Future budget doesn't change history")
check(parseMoney("123.45") == 12345, "Exact paise")
for invalid in ["-1", "0", "1.234", "1e3", "abc", "1000000001"] { check(parseMoney(invalid) == nil, "Invalid amount: \(invalid)") }
check(Category.suggest("Swiggy dinner") == .food, "Suggestion")
let old = ledger.entries[0]
var newer = old; newer.deleted = true; newer.modified = old.modified.addingTimeInterval(10)
ledger.merge([newer]); ledger.merge([old])
check(ledger.entries.first(where: { $0.id == old.id })!.deleted, "Old sync cannot resurrect tombstone")
let roundtrip = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
check(roundtrip.entries == ledger.entries, "Backup roundtrip")
let boundary = ISO8601DateFormatter().date(from: "2026-09-30T18:30:00Z")!
check(Ledger.monthID(boundary) == Ledger.monthID(october), "Bengaluru month boundary")
print("Passed \(checks) ledger checks")

check(ReceiptAmountParser.suggestedAmount(in: "Subtotal 900.00\nGST 45.00\nGrand Total INR 945.00") == 94500, "Prefer grand total over subtotal")
check(ReceiptAmountParser.suggestedAmount(in: "Total ₹1,23,456.78") == 12345678, "Indian comma grouping")
check(ReceiptAmountParser.suggestedAmount(in: "Amount payable\n₹ 250.00") == 25000, "Total on next line")
check(ReceiptAmountParser.suggestedAmount(in: "Total savings 100.00\nTotal tax 20.00") == nil, "Don't treat savings or tax as payable")
check(ReceiptAmountParser.suggestedAmount(in: "Total 120.00\nTotal 240.00") == nil, "Ambiguous totals stay manual")
check(ReceiptAmountParser.suggestedAmount(in: "Phone 9876543210\nGST 18%\nRice 150.00") == nil, "Unlabelled numbers stay manual")
check(ReceiptAmountParser.suggestedAmount(in: "Total 500.00 GST 18%") == 50000, "Ignore percentage after total")
check(ReceiptAmountParser.suggestedAmount(in: "Subtotal 200.00\nNet payable 220.00") == 22000, "Payable total")
let legacyData = try JSONEncoder().encode(old)
let legacyEntry = try JSONDecoder().decode(LedgerEntry.self, from: legacyData)
check(legacyEntry.receiptFilename == nil, "Old entries remain compatible")
var attachment = old; attachment.receiptFilename = UUID().uuidString + ".jpg"; attachment.receiptPath = "personal/user/photo.jpg"
let decodedAttachment = try JSONDecoder().decode(LedgerEntry.self, from: JSONEncoder().encode(attachment))
check(decodedAttachment == attachment, "Receipt reference roundtrip")
print("Passed \(checks) total ledger and receipt checks")

var inbox = Ledger(entries: [LedgerEntry(kind: .contribution, title: "Pool", amount: 100000, date: october)])
var draft = LedgerEntry(kind: .receipt, title: "Photo", amount: 0, date: october, receiptFilename: UUID().uuidString + ".jpg", suggestedAmount: 25000)
inbox.entries.append(draft)
check(inbox.balance(before: Ledger.next(october)) == 100000, "Unreviewed receipt does not change pool")
check(inbox.spent(october) == 0, "OCR suggestion is not booked as spending")
draft.kind = .expense; draft.amount = draft.suggestedAmount!; draft.modified = draft.modified.addingTimeInterval(1)
inbox.merge([draft])
check(inbox.balance(before: Ledger.next(october)) == 75000 && inbox.spent(october) == 25000, "Confirming draft books exactly once")
let inboxBackup = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(inbox))
check(inboxBackup.entries == inbox.entries, "Inbox fields survive backup")
print("Passed \(checks) total checks including receipt inbox")

let receiptText = "HACKER HOUSE CAFE\n04 October 2026\nSubtotal 450.00\nGST 22.50\nGrand Total INR 472.50"
let fields = ReceiptModelFields(merchant: "HACKER HOUSE CAFE", totalINR: "472.50", totalEvidence: "Grand Total INR 472.50", currency: "INR", dateISO: "2026-10-04", dateEvidence: "04 October 2026", category: "Cafes & coworking")
let captureDate = ISO8601DateFormatter().date(from: "2026-10-04T10:00:00Z")!
let valid = ReceiptSuggestions.validated(fields, text: receiptText, captured: captureDate)
check(valid.merchant == "HACKER HOUSE CAFE" && valid.amount == 47250 && valid.category == .workspace && valid.date != nil, "Grounded model fields accepted")
var hallucinated = fields; hallucinated.merchant = "Invented cafe"; hallucinated.totalINR = "999.00"; hallucinated.dateISO = "2026-10-03"; hallucinated.category = "Entertainment"
let rejected = ReceiptSuggestions.validated(hallucinated, text: receiptText, captured: captureDate)
check(rejected.merchant == nil && rejected.amount == nil && rejected.date == nil && rejected.category == nil, "Ungrounded merchant, amount, date and unknown category rejected")
var subtotal = fields; subtotal.totalINR = "450.00"; subtotal.totalEvidence = "Subtotal 450.00"
check(ReceiptSuggestions.validated(subtotal, text: receiptText, captured: captureDate).amount == nil, "Model cannot promote subtotal to payable total")
var conflicting = fields; conflicting.totalINR = "100.00"; conflicting.totalEvidence = "Total 100.00"
check(ReceiptSuggestions.validated(conflicting, text: "Total 100.00\nTotal 200.00", captured: captureDate).amount == nil, "Model cannot resolve conflicting equally ranked totals by guessing")
var foreign = fields; foreign.currency = "USD"
check(ReceiptSuggestions.validated(foreign, text: receiptText, captured: captureDate).amount == nil, "Foreign currency model total rejected")
check(ReceiptSuggestions.validated(fields, text: receiptText + "\nUSD", captured: captureDate).amount == nil, "Receipt currency evidence overrides model currency guess")
var ambiguousDate = fields; ambiguousDate.dateISO = "2026-04-05"; ambiguousDate.dateEvidence = "05/04/2026"
check(ReceiptSuggestions.validated(ambiguousDate, text: "Date 05/04/2026", captured: captureDate).date == nil, "Ambiguous numeric date is left for review")
var futureDate = fields; futureDate.dateISO = "2027-10-04"; futureDate.dateEvidence = "04 October 2027"
check(ReceiptSuggestions.validated(futureDate, text: "04 October 2027", captured: captureDate).date == nil, "Future receipt date rejected")
var madeUpEvidence = fields; madeUpEvidence.totalEvidence = "Grand Total INR 472.50"
check(ReceiptSuggestions.validated(madeUpEvidence, text: "Some cafe\nNo total", captured: captureDate).amount == nil, "Invented total evidence rejected")
let simple = ReceiptSuggestions.fallback(receiptText)
check(simple.amount == 47250 && simple.merchant == "HACKER HOUSE CAFE", "Model unavailable keeps useful OCR fallback")
var modelDraft = LedgerEntry(kind: .receipt, title: "AI receipt", amount: 0, date: captureDate, suggestedAmount: valid.amount, recognizedText: receiptText, suggestedDate: valid.date, receiptAnalysis: "On-device AI suggestions")
let modelDraftRoundtrip = try JSONDecoder().decode(LedgerEntry.self, from: JSONEncoder().encode(modelDraft))
check(modelDraftRoundtrip == modelDraft, "AI review metadata survives sync and backup encoding")
check(Ledger(entries: [modelDraft]).spent(captureDate) == 0, "Model suggestions cannot book spending")
print("Passed \(checks) checks including on-device AI validation")

var cafeMeal = fields; cafeMeal.category = "Food"
check(ReceiptSuggestions.validated(cafeMeal, text: receiptText + "\nSandwich 150.00", captured: captureDate).category == .workspace, "Cafe merchant takes priority over food line items")
var restaurantMeal = fields; restaurantMeal.merchant = "HOUSE RESTAURANT"; restaurantMeal.category = "Food"
check(ReceiptSuggestions.validated(restaurantMeal, text: "HOUSE RESTAURANT\nLunch 150.00", captured: captureDate).category == .food, "Restaurant stays in food category")
print("Passed \(checks) checks including mixed receipt classification")

let budgetMonth = Ledger.start(captureDate)
var privateLimit = LedgerEntry(kind: .budget, title: "Food budget", amount: 300000, date: budgetMonth, category: .food, funding: .personal)
let sharedLimit = LedgerEntry(kind: .budget, title: "Food budget", amount: 900000, date: budgetMonth, category: .food, funding: .pooled)
let budgetLedger = Ledger(entries: [privateLimit, sharedLimit])
check(budgetLedger.budget(budgetMonth, category: .food, funding: .personal) == 300000, "Personal category budget is isolated")
check(budgetLedger.budget(budgetMonth, category: .food) == 900000, "Pooled budget retains backward compatibility")
check(budgetLedger.budget(Ledger.next(budgetMonth), category: .food, funding: .personal) == 300000, "Private category budget carries forward")
check(budgetLedger.balance(before: Ledger.next(budgetMonth)) == 0, "Category limits cannot fund the pool")
print("Passed \(checks) checks including separate personal budgets")

let invitationToken = UUID()
check(RoomInvitation.token(from: RoomInvitation.url(token: invitationToken).absoluteString) == invitationToken, "Invitation app link round trips")
check(RoomInvitation.token(from: " "+invitationToken.uuidString+"\n") == invitationToken, "Legacy invitation code remains accepted")
check(RoomInvitation.token(from: "https://evil.example/invite/"+invitationToken.uuidString) == nil, "Untrusted websites cannot inject invitation tokens")
check(RoomInvitation.token(from: "fgotrack://invite/not-a-token") == nil, "Malformed invitation rejected")
check(RoomInvitation.token(from: "fgotrack://auth/"+invitationToken.uuidString) == nil, "Auth route is never treated as an invitation")
check(RoomInvitation.token(from: "fgotrack://invite/"+invitationToken.uuidString+"/extra") == nil, "Extra invitation path rejected")
check(RoomInvitation.token(from: "fgotrack://invite/"+invitationToken.uuidString+"?room=Forged") == nil, "Untrusted room metadata rejected")
check(RoomInvitation.token(from: "fgotrack://attacker@invite/"+invitationToken.uuidString) == nil, "Invitation credentials are rejected")
print("Passed \(checks) checks including invitation routing")

check(BudgetHealth(spent: 4999, limit: 10000).status == .healthy, "Below 50 percent stays green")
check(BudgetHealth(spent: 5000, limit: 10000).status == .watch, "Exactly 50 percent starts yellow")
check(BudgetHealth(spent: 7999, limit: 10000).status == .watch, "Below 80 percent stays yellow")
check(BudgetHealth(spent: 8000, limit: 10000).status == .nearLimit, "Exactly 80 percent starts red")
check(BudgetHealth(spent: 10000, limit: 10000).status == .reached, "Exactly at limit is red and reached")
check(BudgetHealth(spent: 10001, limit: 10000).status == .over, "Over limit is distinct from near limit")
check(BudgetHealth(spent: 10000, limit: 0).status == .notSet, "Unbudgeted spending never invents a safe status")
check(BudgetHealth(spent: 0, limit: 10000).status == .healthy, "Unused configured budget is healthy")
check(BudgetHealth(spent: 1, limit: 3).status == .healthy && BudgetHealth(spent: 2, limit: 3).status == .watch, "Small paise limits use exact thresholds")
check(BudgetHealth(spent: Int64.max - 1, limit: Int64.max).status == .nearLimit, "Large values cannot overflow threshold calculations")
check(BudgetHealth(spent: 15000, limit: 10000).progress == 1 && BudgetHealth(spent: 15000, limit: 10000).percentage == "150% used", "Overage is visible while progress remains bounded")
check(BudgetHealth.poolStatus(balance: 5000, spent: 5000) == .watch, "Half-funded pool is yellow")
check(BudgetHealth.poolStatus(balance: 2000, spent: 8000) == .nearLimit, "Twenty percent remaining pool is red")
check(BudgetHealth.poolStatus(balance: -100, spent: 0) == .over, "Carried pool deficit is red even with no new expenses")
check(BudgetHealth.poolStatus(balance: 0, spent: 0) == .notSet && BudgetHealth.poolStatus(balance: 0, spent: 100) == .reached, "Empty unfunded and exhausted pools are distinguished")
print("Passed \(checks) checks including budget and pool thresholds")

check(parseBudgetMoney(" 0.00 ") == 0, "Decimal zero can clear a budget")
check(parseBudgetMoney("100.50") == 10050, "Budget entry stores exact paise")
check(parseBudgetMoney("-1") == nil && parseBudgetMoney("1.234") == nil, "Invalid budget limits cannot be saved")
check(parseBudgetMoney("") == nil && parseBudgetMoney("words") == nil, "Empty or nonnumeric budget input is rejected")
print("Passed \(checks) checks including budget entry")

check(BudgetHealth(spent: 3850000, limit: 4350000).percentage == "88% used", "Recurring decimal percentage displays correctly")
check(BudgetHealth(spent: 100000, limit: 600000).percentage == "16% used", "Fractional percentages round down without crossing status thresholds")
print("Passed \(checks) checks including fractional percentages")

let initialForm = EntryFormDraft(title: "Receipt to review", amount: "", date: captureDate, funding: .personal, category: .miscellaneous, person: "", note: "")
var autoForm = initialForm, autoBaseline = initialForm
var backgroundReceipt = LedgerEntry(kind: .receipt, title: "Metro", amount: 0, date: captureDate, category: .travel, funding: .personal, suggestedAmount: 12345, suggestedDate: budgetMonth)
autoForm.receiveReceiptSuggestions(backgroundReceipt, baseline: &autoBaseline)
check(autoForm.amount == "123.45" && autoForm.title == "Metro" && autoForm.category == .travel && autoForm.date == budgetMonth, "Late receipt suggestions refresh untouched review fields")
check(autoForm == autoBaseline, "Background suggestions do not create unsaved user edits")
var typedForm = initialForm, typedBaseline = initialForm
typedForm.amount = "99"; typedForm.title = "My merchant"; typedForm.category = .food; typedForm.date = Ledger.next(captureDate); typedForm.note = "Keep this note"
typedForm.receiveReceiptSuggestions(backgroundReceipt, baseline: &typedBaseline)
check(typedForm.amount == "99" && typedForm.title == "My merchant" && typedForm.category == .food && typedForm.date == Ledger.next(captureDate), "Late OCR cannot overwrite manually corrected fields")
check(typedForm.note == "Keep this note" && typedForm.funding == .personal && typedForm != typedBaseline, "Receipt metadata preserves private source and dirty form state")
var mixedForm = initialForm, mixedBaseline = initialForm; mixedForm.amount = "42"
mixedForm.receiveReceiptSuggestions(backgroundReceipt, baseline: &mixedBaseline)
check(mixedForm.amount == "42" && mixedForm.title == "Metro" && mixedForm != mixedBaseline, "Untouched fields refresh while edited amount remains protected")
var confirmed = backgroundReceipt; confirmed.kind = .expense
var confirmedForm = initialForm, confirmedBaseline = initialForm
confirmedForm.receiveReceiptSuggestions(confirmed, baseline: &confirmedBaseline)
check(confirmedForm == initialForm && confirmedBaseline == initialForm, "Booked expense changes are not auto-applied as OCR suggestions")
print("Passed \(checks) checks including receipt review editing")

check(money(943950).hasSuffix("9,439.50") && !money(4000000).contains("."), "Currency shows two decimals only when paise are present")
check(parseMoney("12,50", locale: Locale(identifier: "de_DE")) == 1250 && parseMoney("12.50", locale: Locale(identifier: "de_DE")) == 1250, "Locale decimal comma accepted from the keypad")
check(parseBudgetMoney("0,00", locale: Locale(identifier: "fr_FR")) == 0, "Locale decimal comma can clear a budget")
check(editableAmount(12345) == "123.45" && editableAmount(47250) == "472.50" && editableAmount(500000) == "5000" && editableAmount(0) == "" && editableAmount(nil) == "", "Editable amounts omit zero")
var merged = ReceiptSuggestions(merchant: "OCR shop", amount: 100, date: nil, category: .food).overridden(by: ReceiptSuggestions(merchant: "AI shop", amount: nil, date: nil, category: nil))
check(merged.merchant == "AI shop" && merged.amount == 100 && merged.category == .food, "AI suggestions override OCR only where grounded")
var manualForm = EntryFormDraft(title: "", amount: "", date: captureDate, funding: .pooled, category: .miscellaneous, person: "", note: "")
var manualBaseline = manualForm; manualForm.amount = "50"
manualForm.receive(merged, baseline: &manualBaseline)
check(manualForm.amount == "50" && manualForm.title == "AI shop" && manualForm.category == .food, "Photo suggestions fill only untouched manual fields")
let many = (0..<2000).map { LedgerEntry(id: "e\($0)", kind: .expense, title: "x", amount: 1, date: october) }
var big = Ledger(entries: many); big.merge(many.map { var e = $0; e.amount = 2; e.modified = e.modified.addingTimeInterval(5); return e })
check(big.entries.count == 2000 && big.spent(october) == 4000, "Large merges update in place without duplicates")
print("Passed \(checks) checks including formatting, locale input and suggestion merging")

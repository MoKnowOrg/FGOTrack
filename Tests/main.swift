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

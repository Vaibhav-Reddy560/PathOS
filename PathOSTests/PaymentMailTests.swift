import Foundation
import Testing
@testable import PathOS

/// Payments read from the mail that confirms them, in the words banks, cards and UPI apps use.
struct PaymentMailTests {
    @Test func anHDFCUPIAlert() throws {
        let payment = try #require(PaymentMail.payment(
            subject: "❗ You have done a UPI txn. Check details!",
            body: "Dear Customer, Rs.250.00 has been debited from account **1234 to VPA swiggy.instamart@hdfcbank SWIGGY on 21-10-26. Your UPI transaction reference number is 429512345678. If you did not authorize this transaction, please report it immediately. Never share your OTP with anyone.",
            isKnownSender: true))
        #expect(payment.amount == 250)
        #expect(payment.payee == "Swiggy")
        #expect(payment.method == .upi)
        #expect(payment.reference == "429512345678")
        #expect(payment.account == "1234")
    }

    @Test func anICICIAlertSkipsTheBalance() throws {
        let payment = try #require(PaymentMail.payment(
            subject: "Transaction alert for your ICICI Bank Account",
            body: "Dear Customer, Your ICICI Bank Account XX123 has been debited for Rs 1,250.00 on 21-Oct-26. Info: UPI-429512345678-ZOMATO. The Available Balance in your Account is Rs 12,345.67.",
            isKnownSender: true))
        #expect(payment.amount == 1_250)
        #expect(payment.payee == "Zomato")
        #expect(payment.reference == "429512345678")
    }

    @Test func aCardAlert() throws {
        let payment = try #require(PaymentMail.payment(
            subject: "Alert : Update on your HDFC Bank Credit Card",
            body: "Dear Card Member,\nThank you for using your HDFC Bank Credit Card ending 4321 for Rs 1,299.00 at AMAZON PAY INDIA PRIVATE on 21-10-2026 14:05:12. Authorization code:- 123456",
            isKnownSender: true))
        #expect(payment.amount == 1_299)
        #expect(payment.payee == "Amazon Pay India Private")
        #expect(payment.method == .card)
        #expect(payment.account == "4321")
    }

    @Test func axisAndKotakAndSBI() throws {
        let axis = try #require(PaymentMail.payment(
            subject: "Debit transaction alert for Axis Bank A/c",
            body: "Amount Debited: INR 80.00\nAccount Number: XX1234\nDate & Time: 21-10-26, 09:12:40 IST\nTransaction Info: UPI/P2M/429512345678/BMRCL",
            isKnownSender: true))
        #expect(axis.amount == 80 && axis.payee == "Bmrcl" && axis.reference == "429512345678")

        let kotak = try #require(PaymentMail.payment(
            subject: "Kotak Bank Transaction Alert",
            body: "Sent Rs.40.00 from Kotak Bank AC X1234 to chaipoint@ybl on 21-10-26. UPI Ref 429512345679.",
            isKnownSender: true))
        #expect(kotak.amount == 40 && kotak.payee == "Chaipoint" && kotak.reference == "429512345679")

        let sbi = try #require(PaymentMail.payment(
            subject: "Transaction Alert",
            body: "Dear Customer, Your A/C XXXXX123456 has a debit by transfer of Rs 500.00 on 21Oct26 transfer to RAMESH KUMAR Ref No 429512345680.",
            isKnownSender: true))
        #expect(sbi.amount == 500 && sbi.payee == "Ramesh Kumar")
    }

    /// Union Bank's alerts: the debit said in the subject and the opening, the payment as fields.
    @Test func aUnionBankAlert() throws {
        #expect(PaymentMail.sender(of: "noreplyubi-txn@ubi.bank.in") == "Union Bank")
        let payment = try #require(PaymentMail.payment(
            subject: "DEBIT TRANSACTION ALERT",
            body: "Dear M VAIBHAV,\n\nGreetings!\n\nYour fund transfer request through UPI has been processed successfully.\n\nTransaction Details\n1. Payee Name : HARISH K\n2. Payee VPA : harishk@okaxis\n3. Amount : Rs.50.00\n4. Transaction Date & Time : 21-10-2026 14:07:12\n5. UPI Ref No / RRN : 629412345678\n6. Remitter Account : XXXXXXXX1234",
            isKnownSender: true))
        #expect(payment.amount == 50 && payment.payee == "Harish K" && payment.reference == "629412345678")
        #expect(payment.account == "1234" && payment.method == .upi)

        // All on one line, as Gmail's preview shows it.
        let flat = try #require(PaymentMail.payment(
            subject: "DEBIT TRANSACTION ALERT",
            body: "Transaction Details 1. Payee Name : HARI PRASAD STORES 2. Payee VPA : paytmqr123@paytm 3. Amount (INR) : 1,250.00 4. RRN : 629412345679",
            isKnownSender: true))
        #expect(flat.amount == 1_250 && flat.payee == "Hari Prasad Stores")

        #expect(PaymentMail.payment(subject: "CREDIT TRANSACTION ALERT",
                                    body: "Your account XXXX1234 has been credited. Transaction Details 1. Remitter Name : RAMESH 2. Amount : Rs.500.00",
                                    isKnownSender: true) == nil)
        #expect(PaymentMail.payment(subject: "DEBIT TRANSACTION ALERT",
                                    body: "Your fund transfer request through UPI has failed. Transaction Details 1. Payee Name : X 2. Amount : Rs.50.00",
                                    isKnownSender: true) == nil)
    }

    @Test func aUPIAppsReceipt() throws {
        let payment = try #require(PaymentMail.payment(
            subject: "Payment successful",
            body: "You paid ₹120 to Third Wave Coffee on 21 Oct 2026. UPI transaction ID: 429512345681",
            isKnownSender: true))
        #expect(payment.amount == 120)
        #expect(payment.payee == "Third Wave Coffee")
    }

    /// Mail that mentions money but where none was spent.
    @Test func notEveryAmountIsSpending() {
        let notSpent = [
            ("Your OTP for transaction", "Your OTP for the transaction of Rs 250.00 is 123456. Do not share."),
            ("Refund processed", "Rs 250.00 has been debited earlier and a refund of Rs 250.00 is credited to your account."),
            ("Transaction declined", "Your transaction of Rs 1,299.00 at AMAZON was declined."),
            ("Credit card statement", "Your statement is ready. Minimum amount due Rs 500.00, payment of Rs 5,000.00 is due on 5 Nov."),
            ("Money received", "Rs 1,000.00 has been credited to your account XX1234 from RAMESH. UPI Ref 429512345682."),
            ("Payment received", "We have received payment of Rs 5,000.00 towards your credit card ending 4321. Thank you."),
            ("Weekend offer", "Get Rs 100 off on your next order. Use code SAVE100."),
        ]
        for (subject, body) in notSpent {
            #expect(PaymentMail.payment(subject: subject, body: body, isKnownSender: true) == nil, "\(subject)")
        }
    }

    /// From someone who isn't a bank, a debit has to look like an alert to count.
    @Test func strangersNeedAnAccountOrAReference() {
        #expect(PaymentMail.payment(subject: "Newsletter", body: "This month we spent Rs 2 crore on new parks.",
                                    isKnownSender: false) == nil)
        #expect(PaymentMail.payment(subject: "Txn alert", body: "Rs 250.00 debited from A/c XX9876 on 21-10-26. UPI Ref 429512345683.",
                                    isKnownSender: false)?.amount == 250)
    }

    @Test func aShopsReceiptTotal() {
        #expect(PaymentMail.receiptTotal(subject: "Your Swiggy order summary",
                                         body: "Item total ₹320\nDelivery fee ₹30\nSubtotal ₹350\nOrder Total\n₹ 362.00\nGet ₹100 off your next order") == 362)
        #expect(PaymentMail.receiptTotal(subject: "Your order has been cancelled", body: "Order Total ₹362") == nil)
    }

    /// Union Bank cuts Bangalore Metro Rail Corporation to "Bangalor": it's Namma Metro.
    @Test func theMetroByAnyName() {
        #expect(PaymentMail.canonicalPayee("Bangalor") == "Namma Metro")
        #expect(PaymentMail.canonicalPayee("BMRCL") == "Namma Metro")
        #expect(PaymentMail.canonicalPayee("Bangalore Electricity Supply") == "Bangalore Electricity Supply")
    }

    @Test func banksAreKnownBySender() {
        #expect(PaymentMail.sender(of: "alerts@hdfcbank.net") == "HDFC Bank")
        #expect(PaymentMail.sender(of: "credit_cards@icicibank.com") == "ICICI Bank")
        #expect(PaymentMail.sender(of: "someone@gmail.com") == nil)
    }

    // MARK: Counting each payment once

    private let noon = Date(timeIntervalSince1970: 1_792_576_800)

    private func entry(_ amount: Double, minutes: Double, source: String, payee: String? = nil, reference: String? = nil,
                       receipt: Bool = false) -> Spending.Entry {
        .init(id: UUID(), at: noon.addingTimeInterval(minutes * 60), amount: amount, payee: payee, source: source,
              method: receipt ? .other : .upi, reference: reference, account: nil, isReceipt: receipt)
    }

    /// The bank's alert and Swiggy's receipt are one payment, named after Swiggy.
    @Test func aReceiptAndItsAlertAreOne() {
        let day = Spending.combined([
            entry(362, minutes: 0, source: "HDFC Bank", payee: "Swiggy Instamart", reference: "1"),
            entry(362, minutes: 55, source: "Swiggy", payee: "Swiggy", receipt: true),
            entry(132, minutes: 200, source: "Uber", payee: "Uber", receipt: true),
        ])
        #expect(day.count == 2)
        #expect(day[0].payee == "Swiggy" && day[0].source == "HDFC Bank")
        #expect(Spending.total(day) == 494)
    }

    /// Two metro tokens of the same price, each with its own reference, are two payments.
    @Test func twoPaymentsOfTheSameAmountAreTwo() {
        let day = Spending.combined([
            entry(40, minutes: 0, source: "HDFC Bank", payee: "BMRCL", reference: "111"),
            entry(40, minutes: 6, source: "HDFC Bank", payee: "BMRCL", reference: "222"),
            entry(40, minutes: 6, source: "HDFC Bank", payee: "BMRCL", reference: "222"),
        ])
        #expect(day.count == 2)
    }
}

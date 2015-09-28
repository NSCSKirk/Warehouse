//
//  Warehouse.swift
//  Succession
//
//  Created by Michael Kirk on 9/20/15.
//  Copyright © 2015 Winterlane, LLC. All rights reserved.
//

import UIKit
import StoreKit

let WarehouseNoProductsNotification = "WarehouseNoProductsNotification"
let WarehouseRetrievedProductsNotification = "WarehouseRetrievedProductsNotification"
let WarehousePaymentProcessingNotification = "WarehousePaymentProcessingNotification"
let WarehousePaymentDeferredNotification = "WarehousePaymentDeferredNotification"
let WarehousePaymentCancelledNotification = "WarehousePaymentCancelledNotification"
let WarehousePaymentFailedNotification = "WarehousePaymentFailedNotification"
let WarehousePaymentCompletedNotification = "WarehousePaymentCompletedNotification"
let WarehouseRestoreFailedNotification = "WarehouseRestoreFailedNotification"
let WarehouseRestoreCompletedNotification = "WarehouseRestoreCompletedNotification"

public enum WarehouseError : ErrorType {
    case InvalidProductIdentifier
}

public enum WarehouseResult {
    case Success
    case Error(NSError)
}

public protocol WarehouseProduct {
    var productId: String { get }
    var isConsumable: Bool { get }
}

public class Warehouse : NSObject {
    static let sharedInstance = Warehouse()
    let WarehouseStorageKey = "WarehouseStorageKey"
    
    var productIdentifiers: [String] {
        didSet {
            retrieveProducts()
        }
    }
    let validator = ReceiptValidator()
    var invalidIdentifiers = [String]()
    var products = [SKProduct]()
    var appReceipt: AppReceipt?
    var productPurchaseCompletion: ((WarehouseResult) -> Void)?
    var productRestoreCompletion: ((WarehouseResult) -> Void)?
    
    override init() {
        productIdentifiers = []
        super.init()
        SKPaymentQueue.defaultQueue().addTransactionObserver(self)
    }
    
    public func purchase(product: SKProduct, completion: (WarehouseResult) -> Void) {
        let payment = SKMutablePayment(product: product)
        productPurchaseCompletion = completion
        SKPaymentQueue.defaultQueue().addPayment(payment)
    }
    
    public func isProductPurchased(productId: String) -> Bool {
        var purchasedProducts = NSUserDefaults.standardUserDefaults().objectForKey(WarehouseStorageKey) as? [String]
        if purchasedProducts == nil {
            purchasedProducts = [String]()
        }
        
        return purchasedProducts!.contains(productId)
    }
    
    public func restorePurchases(completion: (WarehouseResult) -> Void) {
        //Verify receipt?
        self.productRestoreCompletion = completion
        SKPaymentQueue.defaultQueue().restoreCompletedTransactions()
    }
    
    public func canMakePurchases() -> Bool {
        return SKPaymentQueue.canMakePayments()
    }
    
    private func postNotification(name: String, object: AnyObject?) {
        let notification = NSNotification(name: name, object: object)
        NSNotificationCenter.defaultCenter().postNotification(notification)
    }
}

//Product requests
extension Warehouse : SKProductsRequestDelegate {
    
    private func retrieveProducts() {
        let productSet = Set(productIdentifiers)
        let request = SKProductsRequest(productIdentifiers: productSet)
        request.delegate = self
        request.start()
    }
    
    public func productsRequest(request: SKProductsRequest, didReceiveResponse response: SKProductsResponse) {
        products = response.products
        invalidIdentifiers = response.invalidProductIdentifiers
        
        if products.count == 0 {
            let userInfo = [NSLocalizedDescriptionKey : "No products were found."]
            let error = NSError(domain: "com.winterlane.warehouse", code: 1, userInfo: userInfo)
            postNotification(WarehouseNoProductsNotification, object: error)
        } else {
            postNotification(WarehouseRetrievedProductsNotification, object: products)
        }
    }
}

//Payment observation
extension Warehouse : SKPaymentTransactionObserver {
    
    public func paymentQueue(queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .Purchasing: //Being processed by App Store
                postNotification(WarehousePaymentProcessingNotification, object: transaction.payment.productIdentifier)
            case .Deferred: //In queue but waiting on things like "Ask to Buy"
                postNotification(WarehousePaymentDeferredNotification, object: transaction.payment.productIdentifier)
            case .Failed: //Something went wrong
                failedTransaction(transaction)
            case .Purchased: //Product purchased
                completeTransaction(transaction)
            case .Restored: //Single product restored
                restoreTransaction(transaction)
            }
        }
    }
    
    private func failedTransaction(transaction: SKPaymentTransaction) {
        defer { finishTransaction(transaction) }
        guard let error = transaction.error else {
            return
        }
        
        if error.code == SKErrorPaymentCancelled {
            postNotification(WarehousePaymentCancelledNotification, object: transaction.payment.productIdentifier)
        } else {
            postNotification(WarehousePaymentFailedNotification, object: transaction.payment.productIdentifier)
            productPurchaseCompletion?(.Error(error))
        }
    }
    
    private func completeTransaction(transaction: SKPaymentTransaction) {
        validateReceipt { [weak self] result in
            switch result {
            case .Success:
                let productIdentifier = transaction.payment.productIdentifier
                self?.recordPurchase(productIdentifier)
                self?.postNotification(WarehousePaymentCompletedNotification, object: productIdentifier)
                self?.productPurchaseCompletion?(.Success)
                self?.finishTransaction(transaction)
            case .Error(let error):
                self?.productPurchaseCompletion?(.Error(error))
            }
        }
    }
    
    private func restoreTransaction(transaction: SKPaymentTransaction) {
        let productIdentifier = transaction.payment.productIdentifier
        recordPurchase(productIdentifier)
        
        postNotification(WarehouseRestoreCompletedNotification, object: productIdentifier)
        finishTransaction(transaction)
    }
    
    public func paymentQueue(queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: NSError) {
        postNotification(WarehouseRestoreFailedNotification, object: nil)
        productRestoreCompletion?(.Error(error))
    }
    
    public func paymentQueueRestoreCompletedTransactionsFinished(queue: SKPaymentQueue) {
        productRestoreCompletion?(.Success)
    }
    
    private func finishTransaction(transaction: SKPaymentTransaction) {
        SKPaymentQueue.defaultQueue().finishTransaction(transaction)
    }
    
    private func recordPurchase(productId: String) {
        var purchasedProducts = NSUserDefaults.standardUserDefaults().objectForKey(WarehouseStorageKey) as? [String]
        if purchasedProducts == nil {
            purchasedProducts = [String]()
        }
        
        if purchasedProducts?.contains(productId) == false {
            purchasedProducts?.append(productId)
            NSUserDefaults.standardUserDefaults().setObject(purchasedProducts, forKey: WarehouseStorageKey)
        }
    }
}

//Receipt Validation
extension Warehouse {
    
    private func validateReceipt(transaction: SKPaymentTransaction? = nil, completion: (WarehouseResult) -> Void) {
        if let receipt = NSBundle.mainBundle().appStoreReceiptURL, let receiptData = NSData(contentsOfURL: receipt) {
            validator.validate(receiptData) { result in
                dispatch_async(dispatch_get_main_queue(), {
                    switch result {
                    case .Success(let appReceipt):
                        if let transaction = transaction {
                            //Deep rceipt validation
                            if appReceipt.containsPurchase(transaction.payment.productIdentifier) {
                                completion(.Success)
                            } else {
                                let error = NSError(domain: ReceiptValidator.ValidationErrorDomain, code: ReceiptValidator.InAppPurchaseNotFoundErrorCode, description: "The provided transaction was not present inside the validated receipt.")
                                completion(.Error(error))
                            }
                        } else {
                            //No deep receipt validation
                            completion(.Success)
                        }
                    case .Error(let error):
                        completion(.Error(error))
                    }
                })
            }
        } else {
            //Refresh receipt?
            let userInfo = [NSLocalizedDescriptionKey : "The app store receipt could not be found."]
            let error = NSError(domain: "com.winterlane.warehouse", code: 1, userInfo: userInfo)
            completion(.Error(error))
        }
    }
}

enum ValidationResult {
    case Success(AppReceipt)
    case Error(NSError)
}

enum ValidationError : ErrorType {
    case InvalidJSON(String)            // 21000
    case MalformedReceipt(String)       // 21002
    case AuthenticationFailed(String)   // 21003
    case InvalidSecret(String)          // 21004
    case ServerUnavailable(String)      // 21005
    case SubscriptionExpired(String)    // 21006
    case TestReceiptSentToProd(String)  // 21007
    case ProdReceiptSentToTest(String)  // 21008
    case Unknown(String)                // ?????
}

class ReceiptValidator {
    
    let sandboxURL = "https://sandbox.itunes.apple.com/verifyReceipt"
    let productionURL = "https://buy.itunes.apple.com/verifyReceipt"
    static let ValidationErrorDomain = "com.winterlane.warehouse.validation"
    static let UnknownValidationErrorCode = 30000
    static let InvalidResponseJSONErrorCode = 30001
    static let InAppPurchaseNotFoundErrorCode = 30002
    
    func validate(receiptData: NSData, completion: (ValidationResult) -> Void) {
        do {
            let request = try buildRequest(receiptData)
            
            NSURLSession.sharedSession().dataTaskWithRequest(request) { [weak self] (data, response, error) in
                if let validationError = error {
                    completion(.Error(validationError))
                } else if let responseData = data {
                    do {
                        let jsonResponse = try NSJSONSerialization.JSONObjectWithData(responseData, options: NSJSONReadingOptions(rawValue: 0))
                        if let receipt = try self?.parseResponse(jsonResponse) {
                            completion(.Success(receipt))
                        } else {
                            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: ReceiptValidator.UnknownValidationErrorCode, description: "An unknown validation error has occured.")
                        }
                    } catch let jsonError as NSError {
                        completion(.Error(jsonError))
                    }
                }
            }.resume()
        } catch let error as NSError {
            completion(.Error(error))
        }
    }
    
    func buildRequest(receiptData: NSData) throws -> NSURLRequest {
        let requestContents = ["receipt-data" : receiptData.base64EncodedStringWithOptions(NSDataBase64EncodingOptions(rawValue: 0))]
        let requestData = try NSJSONSerialization.dataWithJSONObject(requestContents, options: NSJSONWritingOptions(rawValue: 0))
        let appStoreURL = NSURL(string: sandboxURL)!
        let request = NSMutableURLRequest(URL: appStoreURL)
        request.HTTPMethod = "POST"
        request.HTTPBody = requestData
        
        return request
    }
    
    func parseResponse(jsonResponse: AnyObject) throws -> AppReceipt {
        if let json = jsonResponse as? [String : AnyObject] {
            let status = json["status"] as! Int
            try validateStatusCode(status)
            
            let receiptData = json["receipt"] as! [String : AnyObject]
            return AppReceipt(data: receiptData)
        } else {
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: ReceiptValidator.InvalidResponseJSONErrorCode, description: "The JSON response was not valid.")
        }
    }
    
    func validateStatusCode(status: Int) throws {
        switch status {
        case 0:
            //We have a valid receipt
            break
        case 21000:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "The App Store could not read the JSON object you provided.")
        case 21002:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "The data in the receipt-data property was malformed or missing.")
        case 21003:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "The receipt could not be authenticated.")
        case 21004:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "The shared secret you provided does not match the shared secret on file for your account.")
        case 21005:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "The receipt server is not currently available.")
        case 21006:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "This receipt is valid but the subscription has expired.")
        case 21007:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "This receipt is from the test environment, but it was sent to the production environment for verification. Send it to the test environment instead.")
        case 21008:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: status, description: "This receipt is from the production environment, but it was sent to the test environment for verification. Send it to the production environment instead.")
        default:
            throw NSError(domain: ReceiptValidator.ValidationErrorDomain, code: ReceiptValidator.UnknownValidationErrorCode, description: "An unknown validation code was received.")
        }
    }
}

struct AppReceipt {
    let bundleId: String
    let appVersion: String
    let originalAppVersion: String
    let expirationDate: NSDate?
    let inAppPurchases: [InAppPurchase]
    
    init(data: [String : AnyObject]) {
        if let bundleId = data["bundle_id"] as? String {
            self.bundleId = bundleId
        } else {
            self.bundleId = ""
        }
        
        if let appVersion = data["application_version"] as? String {
            self.appVersion = appVersion
        } else {
            self.appVersion = ""
        }
        
        if let originalAppVersion = data["original_application_version"] as? String {
            self.originalAppVersion = originalAppVersion
        } else {
            self.originalAppVersion = ""
        }
        
        self.expirationDate = nil
        
        if let inAppPurchases = data["in_app"] as? [[String : AnyObject]] {
            var purchases = [InAppPurchase]()
            for purchaseData in inAppPurchases {
                let purchase = InAppPurchase(data: purchaseData)
                purchases.append(purchase)
            }
            self.inAppPurchases = purchases
        } else {
            self.inAppPurchases = [InAppPurchase]()
        }
    }
    
    func containsPurchase(productId: String) -> Bool {
        return inAppPurchases.filter({$0.productId == productId}).count > 0
    }
}

struct InAppPurchase {
    let quantity: Int
    let productId: String
    let transactionId: String
    let originalTransactionId: String
    let purchaseDate: NSDate?
    let originalPurchaseDate: NSDate?
    
    init(data: [String : AnyObject]) {
        if let quantity = data["quantity"] as? Int {
            self.quantity = quantity
        } else {
            self.quantity = 0
        }
        
        if let productId = data["product_id"] as? String {
            self.productId = productId
        } else {
            self.productId = ""
        }
        
        if let transactionId = data["transaction_id"] as? String {
            self.transactionId = transactionId
        } else {
            self.transactionId = ""
        }
        
        if let originalTransactionId = data["original_transaction_id"] as? String {
            self.originalTransactionId = originalTransactionId
        } else {
            self.originalTransactionId = ""
        }
        
        if let purchaseDateMS = data["purchase_date_ms"] as? Double {
            let purchaseDate = purchaseDateMS / 1000
            self.purchaseDate = NSDate(timeIntervalSince1970: purchaseDate)
        } else {
            self.purchaseDate = nil
        }
        
        if let originalPurchaseDateMS = data["original_purchase_date_ms"] as? Double {
            let originalPurchaseDate = originalPurchaseDateMS / 1000
            self.originalPurchaseDate = NSDate(timeIntervalSince1970: originalPurchaseDate)
        } else {
            self.originalPurchaseDate = nil
        }
    }
}

extension NSError {
    convenience init(domain: String, code: Int, description: String) {
        self.init(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey : description])
    }
}

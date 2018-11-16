//
//  TransactionStatusManager.swift
//  Neuron
//
//  Created by 晨风 on 2018/11/16.
//  Copyright © 2018 Cryptape. All rights reserved.
//

import Foundation
import RealmSwift
import BigInt
import Web3swift
import AppChain

enum TransactionStateResult {
    case pending
    case success(transaction: TransactionDetails)
    case failure
}

protocol TransactionStatusManagerDelegate: NSObjectProtocol {
    func sentTransactionInserted(transaction: TransactionDetails)
    func sentTransactionStatusChanged(transaction: TransactionDetails)
}

class TransactionStatusManager: NSObject {
    private typealias Block = () -> Void
    private class Task: NSObject {
        let block: Block
        init(block: @escaping Block) {
            self.block = block
        }
    }

    static let transactionStatusChangedNotification = Notification.Name("transactionStatusChangedNotification")
    static let manager = TransactionStatusManager()
    private var realm: Realm!
    private var transactions = [SentTransaction]()

    private override init() {
        let document = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0], isDirectory: true)
        let fileURL = document.appendingPathComponent("transaction_history")
        try? FileManager.default.removeItem(at: fileURL)
        delegates = NSHashTable(options: .weakMemory)
        super.init()

        createTaskThread()
        perform {
            self.realm = try! Realm(fileURL: fileURL)
            let objects = self.realm.objects(SentTransaction.self)
            self.transactions = objects.filter({ (transaction) -> Bool in
                return transaction.status == .pending
            })
            self.debugLog("加载需要检查状态的交易: \(self.transactions.count)")
        }
        perform {
            self.checkSentTransactionStatus()
        }
    }

    // MARK: - delegate
    private let delegates: NSHashTable<NSObject>!

    func addDelegate(delegate: TransactionStatusManagerDelegate) {
        delegates.add(delegate as? NSObject)
    }

    func removeDelegate(delegate: TransactionStatusManagerDelegate) {
        delegates.remove(delegate as? NSObject)
    }

    // MARK: - Add transaction
    func insertTransaction(transaction: SentTransaction) {
        perform {
            try? self.realm.write {
                self.realm.add(transaction)
            }
            self.transactions.append(transaction)
            self.debugLog("新增交易 \(transaction.txHash)")
            let details = transaction.transactionDetails()
            for delegate in self.delegates.allObjects {
                if let delegate = delegate as? TransactionStatusManagerDelegate {
                    delegate.sentTransactionInserted(transaction: details)
                }
            }
            if self.transactions.count == 1 {
                self.checkSentTransactionStatus()
            }
        }
    }

    // MARK: -
    func getTransactions(walletAddress: String, tokenType: TokenModel.TokenType, tokenAddress: String) -> [TransactionDetails] {
        var transactions: [TransactionDetails]?
        syncPerform {
            let ethereumNetwork = EthereumNetwork().host().absoluteString
            transactions = self.realm.objects(SentTransaction.self).filter({ (transaction) -> Bool in
                return transaction.from == walletAddress &&
                    transaction.tokenType == tokenType &&
                    transaction.contractAddress == tokenAddress &&
                    (transaction.ethereumNetwork == "" || transaction.ethereumNetwork == ethereumNetwork)
            }).map({ (sent) -> TransactionDetails in
                return sent.transactionDetails()
            })
        }
        return transactions ?? []
    }

    // MARK: - Check transaction status
    private let timeInterval: TimeInterval = 4.0

    @objc private func checkSentTransactionStatus() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(checkSentTransactionStatus), object: nil)
        guard self.transactions.count > 0 else {
            debugLog("全部交易状态检查完成")
            return
        }
        guard Thread.current == thread else {
            perform { self.checkSentTransactionStatus() }
            return
        }

        let transactions = self.transactions
        for sentTransaction in transactions {
            let result: TransactionStateResult
            debugLog("开始检查交易状态: \(sentTransaction.txHash)")
            switch sentTransaction.tokenType {
            case .ethereum:
                result = EthereumNetwork().getTransactionStatus(sentTransaction: sentTransaction)
            case .erc20:
                result = EthereumNetwork().getTransactionStatus(sentTransaction: sentTransaction)
            case .nervos:
                result = AppChainNetwork().getTransactionStatus(sentTransaction: sentTransaction)
            default:
                fatalError()
            }

            switch result {
            case .failure:
                debugLog("交易失败: \(sentTransaction.txHash)")
                self.transactions.removeAll { (item) -> Bool in
                    return item == sentTransaction
                }
                try? self.realm.write {
                    sentTransaction.status = .failure
                }
                sentTransactionStatusChanged(transaction: sentTransaction.transactionDetails())
            case .success(let details):
                debugLog("交易成功: \(sentTransaction.txHash)")
                self.transactions.removeAll { (item) -> Bool in
                    return item == sentTransaction
                }
                try? self.realm.write {
                    sentTransaction.status = .success
                    realm.delete(sentTransaction)
                }
                sentTransactionStatusChanged(transaction: details)
            case .pending:
                debugLog("交易进行中: \(sentTransaction.txHash)")
            }
        }
        perform(#selector(checkSentTransactionStatus), with: nil, afterDelay: timeInterval)
    }

    // MARK: - Callback
    private func sentTransactionStatusChanged(transaction: TransactionDetails) {
        for delegate in self.delegates.allObjects {
            if let delegate = delegate as? TransactionStatusManagerDelegate {
                delegate.sentTransactionStatusChanged(transaction: transaction)
            }
        }
    }

    // MARK: - Thread
    private var thread: Thread!

    @objc private func perform(_ block: @escaping Block) {
        if Thread.current == thread {
            block()
            return
        }
        let task = Task(block: block)
        let sel = #selector(TransactionStatusManager.taskHandler(task:))
        self.perform(sel, on: self.thread, with: task, waitUntilDone: false)
    }

    @objc private func syncPerform(_ block: @escaping Block) {
        if Thread.current == thread {
            block()
            return
        }
        let task = Task(block: block)
        let sel = #selector(TransactionStatusManager.taskHandler(task:))
        self.perform(sel, on: self.thread, with: task, waitUntilDone: true)
    }

    @objc private func taskHandler(task: Task) {
        task.block()
    }

    //    func value<T>(_ block: (TransactionStatusManager) -> T) -> T {
    //        let value = block(self)
    //        return value
    //    }

    private func createTaskThread() {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "")
        group.enter()
        queue.async {
            self.thread = Thread.current
            Thread.current.name = String(describing: TransactionStatusManager.self)
            RunLoop.current.add(NSMachPort(), forMode: .default)
            group.leave()
            RunLoop.current.run()
        }
        group.wait()
    }

    // MARK: - Utils
    private var isEnableDebugLog = false
    private func debugLog(_ text: String) {
        if isEnableDebugLog {
            print("[TransactionStatus] - \(text)")
        }
    }
}

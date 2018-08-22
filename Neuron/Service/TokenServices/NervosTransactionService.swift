//
//  NervosTransactionService.swift
//  Neuron
//
//  Created by XiaoLu on 2018/8/22.
//  Copyright © 2018年 Cryptape. All rights reserved.
//

import Foundation
import Nervos
import BigInt
//import web3swift

protocol NervosTransactionServiceProtocol {
    func prepareTransactionForSending(address: String,
                                      nonce: String,
                                      quota: BigUInt,
                                      data: Data,
                                      value: String,
                                      chainId: BigUInt, completion: @escaping (SendNervosResult<NervosTransaction>) -> Void)

    func send(password: String, transaction: NervosTransaction, completion: @escaping (SendNervosResult<TransactionSendingResult>) -> Void)
}

class NervosTransactionServiceImp: NervosTransactionServiceProtocol {

    func prepareTransactionForSending(address: String,
                                      nonce: String = "",
                                      quota: BigUInt = BigUInt(100000),
                                      data: Data,
                                      value: String,
                                      chainId: BigUInt, completion: @escaping (SendNervosResult<NervosTransaction>) -> Void) {
        DispatchQueue.global().async {
            guard let destinationEthAddress = Address(address) else {
                DispatchQueue.main.async {
                    completion(SendNervosResult.Error(SendNervosErrors.invalidDestinationAddress))
                }
                return
            }
            guard let amount = Utils.parseToBigUInt(value, units: .eth) else {
                DispatchQueue.main.async {
                    completion(SendNervosResult.Error(SendNervosErrors.invalidAmountFormat))
                }
                return
            }
            let nonce = UUID().uuidString
            let nervos = NervosNetwork.getNervos()
            let result = nervos.appChain.blockNumber()
            DispatchQueue.main.async {
                switch result {
                case .success(let blockNumber):
                    let transaction = NervosTransaction.init(to: destinationEthAddress, nonce: nonce, data: data, value: amount, validUntilBlock: blockNumber + BigUInt(88), quota: quota, version: BigUInt(0), chainId: chainId)
                    completion(SendNervosResult.Success(transaction))
                case .failure(let error):
                    completion(SendNervosResult.Error(error))
                }
            }
        }
    }
    func send(password: String, transaction: NervosTransaction, completion: @escaping (SendNervosResult<TransactionSendingResult>) -> Void) {
        let nervos = NervosNetwork.getNervos()
        let walletModel = WalletRealmTool.getCurrentAppmodel().currentWallet!
        var privateKey = CryptTools.Decode_AES_ECB(strToDecode: walletModel.encryptPrivateKey, key: password)
        if privateKey.hasPrefix("0x") {
            privateKey = String(privateKey.dropFirst(2))
        }
        guard let signed = try? NervosTransactionSigner.sign(transaction: transaction, with: privateKey) else {
            completion(SendNervosResult.Error(NervosSignErrors.signTXFailed))
            return
        }
        DispatchQueue.global().async {
            let result = nervos.appChain.sendRawTransaction(signedTx: signed)
            DispatchQueue.main.async {
                switch result {
                case .success(let transaction):
                    completion(SendNervosResult.Success(transaction))
                case .failure(let error):
                    completion(SendNervosResult.Error(error))
                }
            }
        }
    }
}

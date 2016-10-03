//
//  CertificateValidationRequest.swift
//  cert-wallet
//
//  Created by Chris Downie on 8/19/16.
//  Copyright © 2016 Digital Certificates Project. All rights reserved.
//

import Foundation
import JSONLD

// From the example web verifier here:
//
//Step 1 of 5... Computing SHA256 digest of local certificate [DONE]
//Step 2 of 5... Fetching hash in OP_RETURN field [DONE]
//Step 3 of 5... Comparing local and blockchain hashes [PASS]
//Step 4 of 5... Checking Media Lab signature [PASS]
//Step 5 of 5... Checking not revoked by issuer [PASS]
//Success! The certificate has been verified.
enum ValidationState {
    case notStarted
    case computingLocalHash, fetchingRemoteHash, comparingHashes, checkingIssuerSignature, checkingRevokedStatus
    case success
    case failure(reason : String)
    // these are v1.2
    case checkingReceipt, checkingMerkleRoot
}

protocol CertificateValidationRequestDelegate : class {
    func certificateValidationStateChanged(from: ValidationState, to: ValidationState)
}

extension CertificateValidationRequestDelegate {
    func certificateValidationStateChanged(from: ValidationState, to: ValidationState) {
        // By default, do nothing.
    }
}

class CertificateValidationRequest : CommonRequest {
    let session : URLSessionProtocol
    let jsonld : JSONLDProcessor
    let certificate : Certificate
    let transactionId : String
    var completionHandler : ((Bool, String?) -> Void)?
    weak var delegate : CertificateValidationRequestDelegate?
    let chain : String

    var state = ValidationState.notStarted {
        didSet {
            // Notify the delegate
            delegate?.certificateValidationStateChanged(from: oldValue, to: state)
            
            // Perform the action associated with the new state
            switch state {
            case .notStarted:
                break
            case .success:
                completionHandler?(true, nil)
            case .failure(let reason):
                completionHandler?(false, reason)
            case .computingLocalHash:
                self.computeLocalHash()
            case .fetchingRemoteHash:
                self.fetchRemoteHash()
            case .comparingHashes:
                self.compareHashes()
            case .checkingIssuerSignature:
                self.checkIssuerSignature()
            case .checkingRevokedStatus:
                self.checkRevokedStatus()
            case .checkingMerkleRoot:
                self.checkMerkleRoot()
            case .checkingReceipt:
                self.checkReceipt()
            }
        }
    }
    
    // Private state built up over the validation sequence
    var localHash : Data? // or String?
    var remoteHash : String? // or String?
    private var revokationKey : String?
    private var revokedAddresses : Set<String>?
    
    init(for certificate: Certificate,
         with transactionId: String,
         chain: String = "mainnet",
         starting : Bool = false,
         jsonld : JSONLDProcessor = JSONLD.shared,
         session : URLSessionProtocol = URLSession.shared,
         completionHandler: ((Bool, String?) -> Void)? = nil) {
        self.session = session
        self.jsonld = jsonld
        self.certificate = certificate
        self.transactionId = transactionId
        self.completionHandler = completionHandler
        self.chain = chain
        
        if (starting) {
            self.start()
        }
    }
    
    convenience init?(for certificate: Certificate,
                     chain: String = "mainnet",
                     starting : Bool = false,
                     jsonld : JSONLDProcessor = JSONLD.shared,
                     session: URLSessionProtocol = URLSession.shared,
                     completionHandler: ((Bool, String?) -> Void)? = nil) {
        guard let transactionId = certificate.receipt?.transactionId else {
            // To use this init function
            return nil
        }
        
        self.init(for: certificate,
                  with: transactionId,
                  chain: chain,
                  starting: starting,
                  jsonld: jsonld,
                  session: session,
                  completionHandler: completionHandler)
    }
    
    func start() {
        state = .computingLocalHash
    }
    
    func abort() {
        state = .failure(reason: "Aborted")
    }
    
    internal func computeLocalHash() {
        if certificate.version == .oneDotOne {
            self.localHash = sha256(data: certificate.file)
            state = .fetchingRemoteHash
        } else {
            let docData : Data!
            do {
                let json = try JSONSerialization.jsonObject(with: certificate.file, options: []) as! [String: Any]
                let document = json["document"] as! [String: Any]
                docData = try JSONSerialization.data(withJSONObject: document, options: [])
            } catch {
                state = .failure(reason: "Failed to re-parse the document node out of the certificate's file.")
                return
            }
            
            jsonld.normalize(docData: docData, callback: { (error, resultString) in
                guard error == nil else {
                    self.state = .failure(reason: "Failed JSON-LD compact with \(error!)")
                    return
                }
                guard let resultString = resultString else {
                    self.state = .failure(reason: "There's no error, but the resultData is nil.")
                    return
                }
                guard let stringData = resultString.data(using: .utf8) else {
                    self.state = .failure(reason: "Result could not be translated into raw data: \(resultString)")
                    return
                }
                
                self.localHash = sha256(data: stringData)
                self.state = .fetchingRemoteHash
            })
        }
    }
    
    internal func fetchRemoteHash() {
        let transactionDataHandler = TransactionDataHandler.create(chain: self.chain, transactionId: transactionId)
        
        guard let transactionUrl = URL(string: transactionDataHandler.transactionUrlAsString!) else {
            state = .failure(reason: "Transaction ID (\(transactionId)) is invalid")
            return
        }
        let task = session.dataTask(with: transactionUrl) { [weak self] (data, response : URLResponse?, _) in
            guard let response = response as? HTTPURLResponse,
                response.statusCode == 200 else {
                self?.state = .failure(reason: "Got invalid response from \(transactionUrl)")
                return
            }
            guard let data = data else {
                self?.state = .failure(reason: "Got a valid response, but no data from \(transactionUrl)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String : AnyObject] else {
                self?.state = .failure(reason: "Transaction didn't return valid JSON data from \(transactionUrl)")
                return
            }
            
            // Let's parse the OP_RETURN value out of the data.
            transactionDataHandler.parseResponse(json: json!)
            guard let transactionData = transactionDataHandler.transactionData else {
                self?.state = .failure(reason: transactionDataHandler.failureReason!)
                return
            }
            
            self?.remoteHash = transactionData.opReturnScript
            self?.revokedAddresses = transactionData.revokedAddresses
            
            self?.state = .comparingHashes
        }
        task.resume()
    }
    
    internal func compareHashes() {
        let compareToHash : String?
        if certificate.version == .oneDotOne {
            compareToHash = self.remoteHash
        } else {
            compareToHash = self.certificate.receipt?.targetHash
        }
        
        guard let localHash = self.localHash,
            let correctHashResult = compareToHash?.asHexData() else {
                state = .failure(reason: "Can't compare hashes: at least one hash is still nil")
                return
        }
        
        guard localHash == correctHashResult else {
            state = .failure(reason: "Local hash doesn't match remote hash:\n Local:\(localHash)\nRemote\(remoteHash)")
            return
        }
        
        if certificate.version == .oneDotOne {
            state = .checkingIssuerSignature
        } else {
            state = .checkingMerkleRoot
        }
    }
    internal func checkIssuerSignature() {
        let url = certificate.issuer.id
        let request = session.dataTask(with: certificate.issuer.id) { [weak self] (data, response, error) in
            guard let response = response as? HTTPURLResponse,
                response.statusCode == 200 else {
                    self?.state = .failure(reason: "Got invalid response from \(url)")
                    return
            }
            guard let data = data else {
                self?.state = .failure(reason: "Got a valid response, but no data from \(url)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as! [String: AnyObject] else {
                self?.state = .failure(reason: "Certificate didn't return valid JSON data from \(url)")
                return
            }
            guard let issuerKeys = json["issuerKeys"] as? [[String : String]],
                let revokationKeys = json["revocationKeys"] as? [[String : String]] else {
                    self?.state = .failure(reason: "Couldn't parse issuerKeys or revokationKeys from json: \n\(json)")
                    return
            }
            guard let issuerKey = issuerKeys.first?["key"],
                let revokeKey = revokationKeys.first?["key"] else {
                    self?.state = .failure(reason: "Couldn't parse first issueKey or revokeKey")
                    return
            }
            self?.revokationKey = revokeKey
            
            // Check the issuer key: here's how it works:
            // 1. base64 decode the signature that's on the certificate ('signature') field
            // 2. use the CoreBitcoin library method BTCKey.verifySignature to derive the key used to create this signature:
            //    - it takes as input the signature on the certificate and the message (the assertion uid) that we expect it to be the signature of.
            //    - it returns a matching BTCKey if found
            // 3. we still have to check that the BTCKey returned above matches the issuer's public key that we looked up
            
            // base64 decode the signature on the certificate
            let decodedData = NSData.init(base64Encoded: (self?.certificate.signature)!, options: NSData.Base64DecodingOptions(rawValue: 0))
            // derive the key that produced this signature
            let btcKey = BTCKey.verifySignature(decodedData as Data!, forMessage: self?.certificate.assertion.uid)
            // if this succeeds, we successfully derived a key, but still have to check that it matches the issuerKey
            
            
            let address : String?
            if self?.chain == "testnet" {
                address = btcKey?.addressTestnet?.string
            } else {
                address = btcKey?.address?.string
            }
            
            guard address == issuerKey else {
                self?.state = .failure(reason: "Issuer key doesn't match derived address:\n Address\(address)\n issuerKey\(issuerKey)")
                return
            }
            
            self?.state = .checkingRevokedStatus
        }
        request.resume()
    }
    
    internal func checkRevokedStatus() {
        let batchRevoked : Bool = (revokedAddresses?.contains(self.revokationKey!))!
        if batchRevoked {
            self.state = .failure(reason: "Certificate Batch has been revoked by issuer. Revocation key is \(self.revokationKey!)")
            return
        }
        if self.certificate.recipient.revocationAddress != nil {
            let certificateRevoked : Bool = (revokedAddresses?.contains(self.certificate.recipient.revocationAddress!))!
            if certificateRevoked {
                self.state = .failure(reason: "Certificate has been revoked by issuer. Revocation key is \(self.certificate.recipient.revocationAddress!)")
                return
            }
        }
        // Success
        state = .success
    }
    
    func checkMerkleRoot() {
        guard certificate.version == .oneDotTwo else {
            state = .failure(reason: "Invalid state. Shouldn't need to check merkle root for this version of the cert format")
            return
        }
        
        // compare merkleRoot to blockchain
        guard let merkleRoot = certificate.receipt?.merkleRoot,
            let remoteHash = self.remoteHash else {
                state = .failure(reason: "Can't compare hashes: at least one hash is still nil")
                return
        }
        
        let opReturnPrefixedMerkleRoot = "6a20" + merkleRoot
        guard opReturnPrefixedMerkleRoot == remoteHash else {
            state = .failure(reason: "MerkleRoot does not match remote hash:\n Merkle:\(merkleRoot)\nRemote:\(remoteHash)")
            return
        }
        
        state = .checkingReceipt
    }
    
    func checkReceipt() {
        guard certificate.version == .oneDotTwo else {
            state = .failure(reason: "Invalid state. Shouldn't need to check receipt for this version of the cert format")
            return
        }
        
        let isReceiptValid = ReceiptVerifier().validate(receipt: certificate.receipt!, chain: chain)
        guard isReceiptValid else {
            state = .failure(reason: "Invalid Merkle Receipt:\n Receipt\(certificate.receipt!)")
            return
        }
        state = .checkingIssuerSignature
    }
}

// MARK: helper functions
func sha256(data : Data) -> Data {
    var hash = [UInt8](repeating: 0,  count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
        _ = CC_SHA256($0, CC_LONG(data.count), &hash)
    }
    return Data(bytes: hash)
}

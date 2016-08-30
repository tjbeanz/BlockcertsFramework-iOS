//
//  CertificateValidationRequest.swift
//  cert-wallet
//
//  Created by Chris Downie on 8/19/16.
//  Copyright © 2016 Digital Certificates Project. All rights reserved.
//

import Foundation

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
    // TODO: these are v1.2
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

class CertificateValidationRequest {
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
    
    init(for certificate: Certificate, with transactionId: String, chain: String = "mainnet", starting : Bool = false, completionHandler: ((Bool, String?) -> Void)? = nil) {
        self.certificate = certificate
        self.transactionId = transactionId
        self.completionHandler = completionHandler
        self.chain = chain
        
        if (starting) {
            self.start()
        }
    }
    
    // TODO: set chain
    
    func start() {
        state = .computingLocalHash
    }
    
    func abort() {
        state = .failure(reason: "Aborted")
    }
    
    internal func computeLocalHash() {
        self.localHash = sha256(data: certificate.file)
        state = .fetchingRemoteHash
    }
    internal func fetchRemoteHash() {
        
        // todo: what is proper init pattern here?
        let transactionDataHandler : TransactionDataHandler = TransactionDataHandler.create(chain: self.chain, transactionId: transactionId)
        
        guard let transactionUrl = URL(string: transactionDataHandler.transactionUrlAsString!) else {
            state = .failure(reason: "Transaction ID (\(transactionId)) is invalid")
            return
        }
        let task = URLSession.shared.dataTask(with: transactionUrl) { [weak self] (data, response : URLResponse?, _) in
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
            guard let transactionData : TransactionData = transactionDataHandler.transactionData else {
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

        guard let localHash = self.localHash,
            let remoteHash = self.remoteHash?.asHexData() else {
                state = .failure(reason: "Can't compare hashes: at least one hash is still nil")
                return
        }
        
        guard localHash == remoteHash else {
            state = .failure(reason: "Local hash doesn't match remote hash:\n Local:\(localHash)\nRemote\(remoteHash)")
            return
        }
        state = .checkingIssuerSignature
    }
    internal func checkIssuerSignature() {
        let url = certificate.issuer.id
        let request = URLSession.shared.dataTask(with: certificate.issuer.id) { [weak self] (data, response, error) in
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
            guard let issuerKeys = json["issuer_key"] as? [[String : String]],
                let revokationKeys = json["revocation_key"] as? [[String : String]] else {
                    self?.state = .failure(reason: "Couldn't parse issuer_key or revokation_key from json: \n\(json)")
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
            
            // TODO: this is awkward
            if self?.chain == "testnet" {
                if btcKey?.addressTestnet?.string != issuerKey {
                    self?.state = .failure(reason: "Didn't check the issuer key \(issuerKey)")
                    return
                }
            } else {
                if btcKey?.address?.string != issuerKey {
                    self?.state = .failure(reason: "Didn't check the issuer key \(issuerKey)")
                    return
                }
            }
            self?.state = .checkingRevokedStatus
        }
        request.resume()
    }
    
    internal func checkRevokedStatus() {
        let revoked : Bool = (revokedAddresses?.contains(self.revokationKey!))!
        if revoked {
            self.state = .failure(reason: "Certificate has been revoked by issuer. Revocation key is \(self.revokationKey!)")
            return
        }
        // Success
        state = .success
    }
    
    func checkMerkleRoot() {
        // no-op TODO: bad
    }
    func checkReceipt() {
        // no-op TODO: bad
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

class CertificateValidationRequestV2 : CertificateValidationRequest {

    init(for certificate: Certificate, chain: String = "mainnet", starting : Bool = false, completionHandler: ((Bool, String?) -> Void)? = nil) {
        let receipt: Receipt = certificate.receipt!
        let transactionId = receipt.transactionId
        super.init(for: certificate, with: transactionId, chain: chain, starting: starting, completionHandler: completionHandler)

        if (starting) {
            super.start()
        }
    }
    
    /**
     * TODO!! the local hash is computed differently in v2, but I can't find swift json ld libraries to support this.
     * When available, this needs to be replaced with a call to jsonld.normalize(cert["document"]) and then hash
     */
    override func computeLocalHash() {
        // TOOD: implement behavior in comments when json ld libraries are available for swift
        state = .fetchingRemoteHash
    }
    
    /**
     * Verify the merkle receipt
     */
    override func checkReceipt() {
        let verifier : ReceiptVerifier = ReceiptVerifier()
        let valid = verifier.validate(receipt: certificate.receipt!, chain: super.chain)
        guard valid == true else {
            state = .failure(reason: "Invalid Merkle Receipt:\n Receipt\(certificate.receipt!)")
            return
        }
        state = .checkingIssuerSignature
    }
    
    /**
     * TODO!! see above comment about json ld library
     * Override v1 compareHashes comparison. 
     *
     * Compare local hash to targetHash in receipt.
     */
    override func compareHashes() {
        //
        
        /*guard let targetHash = super.certificate.receipt?.targetHash.asHexData(),
            let localHash = self.localHash else {
                state = .failure(reason: "Can't compare hashes: at least one hash is still nil")
                return
        }
        guard targetHash == localHash else {
            state = .failure(reason: "Local hash doesn't match remote hash:\n Local:\(localHash)\nRemote\(remoteHash)")
            return
        }*/
        
        state = .checkingMerkleRoot
    }
    
    override func checkMerkleRoot() {
        // compare merkleRoot to blockchain
        
        guard let merkleRoot = super.certificate.receipt?.merkleRoot,
            let remoteHash = self.remoteHash else {
                state = .failure(reason: "Can't compare hashes: at least one hash is still nil")
                return
        }
        
        guard merkleRoot == remoteHash else {
            state = .failure(reason: "Local hash doesn't match remote hash:\n Local:\(localHash)\nRemote\(remoteHash)")
            return
        }
        
        state = .checkingReceipt
    }
    
}
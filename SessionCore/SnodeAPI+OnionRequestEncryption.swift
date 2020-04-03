import _25519
import CryptoSwift
import PromiseKit

extension SnodeAPI {
    internal static let gcmTagSize: UInt = 16
    internal static let ivSize: UInt = 12

    internal typealias EncryptionResult = (ciphertext: Data, symmetricKey: Data, ephemeralPublicKey: Data)

    private static func getQueue() -> DispatchQueue {
        return DispatchQueue(label: UUID().uuidString, qos: .userInitiated)
    }

    /// Returns `size` bytes of random data generated using the default secure random number generator. See
    /// [SecRandomCopyBytes](https://developer.apple.com/documentation/security/1399291-secrandomcopybytes) for more information.
    private static func getSecureRandomData(ofSize size: UInt) throws -> Data {
        var data = Data(count: Int(size))
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Int(size), $0.baseAddress!) }
        guard result == errSecSuccess else { throw Error.randomDataGenerationFailed }
        return data
    }

    /// - Note: Sync. Don't call from the main thread.
    private static func encrypt(_ plaintext: Data, usingAESGCMWithSymmetricKey symmetricKey: Data) throws -> Data {
        guard !Thread.isMainThread else { preconditionFailure("It's illegal to call encrypt(_:usingAESGCMWithSymmetricKey:) from the main thread.") }
        let iv = try getSecureRandomData(ofSize: ivSize)
        let gcm = GCM(iv: iv.bytes, tagLength: Int(gcmTagSize), mode: .combined)
        let aes = try AES(key: symmetricKey.bytes, blockMode: gcm, padding: .pkcs7)
        let ciphertext = try aes.encrypt(plaintext.bytes)
        return iv + Data(ciphertext)
    }

    /// - Note: Sync. Don't call from the main thread.
    private static func encrypt(_ plaintext: Data, forSnode snode: Snode) throws -> EncryptionResult {
        guard !Thread.isMainThread else { preconditionFailure("It's illegal to call encrypt(_:forSnode:) from the main thread.") }
        let hexEncodedSnodeX25519PublicKey = snode.publicKeySet.x25519Key
        let snodeX25519PublicKey = Data(hex: hexEncodedSnodeX25519PublicKey)
        guard let ephemeralKeyPair = Curve25519.generateKeyPair() else { throw Error.keyPairGenerationFailed }
        guard let ephemeralSharedSecret = Curve25519.generateSharedSecret(fromPublicKey: snodeX25519PublicKey, andKeyPair: ephemeralKeyPair) else { throw Error.sharedSecretGenerationFailed }
        let key = "LOKI"
        let symmetricKey = try HMAC(key: key.bytes, variant: .sha256).authenticate(ephemeralSharedSecret.bytes)
        let ciphertext = try encrypt(plaintext, usingAESGCMWithSymmetricKey: Data(symmetricKey))
        return (ciphertext, Data(symmetricKey), ephemeralKeyPair.publicKey())
    }

    /// Encrypts `payload` for `snode` and returns the result. Use this to build the core of an onion request.
    internal static func encrypt(_ payload: JSON, forTargetSnode snode: Snode) -> Promise<EncryptionResult> {
        let (promise, seal) = Promise<EncryptionResult>.pending()
        getQueue().async {
            do {
                guard JSONSerialization.isValidJSONObject(payload) else { return seal.reject(HTTP.Error.invalidJSON) }
                let payloadAsData = try JSONSerialization.data(withJSONObject: payload, options: [])
                let payloadAsString = String(data: payloadAsData, encoding: .utf8)! // Snodes only accept this as a string
                let wrapper: JSON = [ "body" : payloadAsString, "headers" : "" ]
                guard JSONSerialization.isValidJSONObject(wrapper) else { return seal.reject(HTTP.Error.invalidJSON) }
                let plaintext = try JSONSerialization.data(withJSONObject: wrapper, options: [])
                let result = try encrypt(plaintext, forSnode: snode)
                seal.fulfill(result)
            } catch (let error) {
                seal.reject(error)
            }
        }
        return promise
    }

    /// Encrypts the previous encryption result (i.e. that of the hop after this one) for this hop. Use this to build the layers of an onion request.
    internal static func encryptHop(from lhs: Snode, to rhs: Snode, using previousEncryptionResult: EncryptionResult) -> Promise<EncryptionResult> {
        let (promise, seal) = Promise<EncryptionResult>.pending()
        getQueue().async {
            let parameters: JSON = [
                "ciphertext" : previousEncryptionResult.ciphertext.base64EncodedString(),
                "ephemeral_key" : previousEncryptionResult.ephemeralPublicKey.toHexString(),
                "destination" : rhs.publicKeySet.ed25519Key
            ]
            do {
                guard JSONSerialization.isValidJSONObject(parameters) else { return seal.reject(HTTP.Error.invalidJSON) }
                let plaintext = try JSONSerialization.data(withJSONObject: parameters, options: [])
                let result = try encrypt(plaintext, forSnode: lhs)
                seal.fulfill(result)
            } catch (let error) {
                seal.reject(error)
            }
        }
        return promise
    }
}

# Standard .NET cryptography is called from C# because PowerShell cannot bind
# every ReadOnlySpan overload used by PEM import. No credential is emitted.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
public static class RightclickRelayEnvelope {
    public static Dictionary<string, string> Encrypt(byte[] plaintext, string publicPem) {
        using (RSA rsa = RSA.Create()) {
            rsa.ImportFromPem(publicPem);
            if (rsa.KeySize < 3072) throw new ArgumentException("Operator RSA key must have at least 3072 bits");
            byte[] key = RandomNumberGenerator.GetBytes(32);
            byte[] nonce = RandomNumberGenerator.GetBytes(12);
            byte[] ciphertext = new byte[plaintext.Length];
            byte[] tag = new byte[16];
            byte[] aad = Encoding.UTF8.GetBytes("RIGHTCLICK-WINDOWS-RELAY-v1");
            using (AesGcm aes = new AesGcm(key, 16)) aes.Encrypt(nonce, plaintext, ciphertext, tag, aad);
            byte[] wrapped = rsa.Encrypt(key, RSAEncryptionPadding.OaepSHA256);
            CryptographicOperations.ZeroMemory(key);
            return new Dictionary<string, string> {
                {"algorithm", "RSA-OAEP-SHA256+AES-256-GCM"},
                {"aad", "RIGHTCLICK-WINDOWS-RELAY-v1"},
                {"publicKeyDER_SHA256", Convert.ToHexString(SHA256.HashData(rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()},
                {"wrappedKey", Convert.ToBase64String(wrapped)},
                {"nonce", Convert.ToBase64String(nonce)},
                {"ciphertext", Convert.ToBase64String(ciphertext)},
                {"tag", Convert.ToBase64String(tag)}
            };
        }
    }
}
'@

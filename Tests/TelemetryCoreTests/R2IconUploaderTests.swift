import Foundation
import Testing

@testable import TelemetryCore

/**
 * SigV4 的期望值是用一份独立的 Python 参考实现算出来后钉死的，不是拿这里的
 * 代码自己算一遍再和自己比。改动签名逻辑时这几个值不该跟着改 —— 它们变了
 * 就意味着 R2 那边收到的请求也变了。
 */
struct R2IconUploaderTests {
    private let configuration = R2UploadConfiguration(
        endpoint: URL(string: "https://acc.r2.cloudflarestorage.com")!,
        bucket: "icons",
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    )
    /// 2026-09-11T04:05:06Z
    private let now = Date(timeIntervalSince1970: 1_789_099_506)
    private let payload = Data("telemetry-core-test".utf8)

    @Test func amzTimestampIsCompactUTCWithZuluSuffix() {
        #expect(R2IconUploader.timestamp(Date(timeIntervalSince1970: 0)) == "19700101T000000Z")
        #expect(R2IconUploader.timestamp(now) == "20260911T040506Z")
        // 小数秒截断而不是四舍五入
        #expect(R2IconUploader.timestamp(Date(timeIntervalSince1970: 1_789_099_506.9)) == "20260911T040506Z")
    }

    @Test func objectURLJoinsBucketAndKeyOntoEndpointPath() throws {
        let url = try R2IconUploader.objectURL(
            endpoint: configuration.endpoint,
            bucket: configuration.bucket,
            objectKey: "abc123.png"
        )
        #expect(url.absoluteString == "https://acc.r2.cloudflarestorage.com/icons/abc123.png")
    }

    @Test func putSignatureMatchesTheReferenceVector() throws {
        let url = try R2IconUploader.objectURL(
            endpoint: configuration.endpoint,
            bucket: configuration.bucket,
            objectKey: "abc123.png"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        R2IconUploader.sign(
            &request,
            payloadHash: R2IconUploader.contentHash(of: payload),
            contentType: "image/png",
            method: "PUT",
            url: url,
            configuration: configuration,
            now: now
        )

        #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20260911T040506Z")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256")
            == "db02ab6807f9ccbf6175e81ac44e12b5f765b58d84efe15accceff3fc162f9aa")
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
            AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260911/auto/s3/aws4_request, \
            SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, \
            Signature=5d8ac96981e137d34cde07dbcefb088d081831f732e3b3257f73f0b6253e38f8
            """)
    }

    /// HEAD 不带 content-type，签名头列表因此少一项。
    @Test func headSignatureOmitsContentTypeFromSignedHeaders() throws {
        let url = try R2IconUploader.objectURL(
            endpoint: configuration.endpoint,
            bucket: configuration.bucket,
            objectKey: "abc123.png"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        R2IconUploader.sign(
            &request,
            payloadHash: R2IconUploader.emptyPayloadHash,
            contentType: nil,
            method: "HEAD",
            url: url,
            configuration: configuration,
            now: now
        )

        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
            AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260911/auto/s3/aws4_request, \
            SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
            Signature=1e92c1af736d4acdc953171efefd45c335438b1c45890231798dafa7c99184f7
            """)
    }

    @Test func emptyPayloadHashIsTheSHA256OfNothing() {
        #expect(R2IconUploader.emptyPayloadHash == R2IconUploader.contentHash(of: Data()))
    }

    @Test func objectKeyIsContentAddressedWithTheGivenExtension() {
        let key = R2IconUploader.objectKey(for: payload)
        #expect(key == "db02ab6807f9ccbf6175e81ac44e12b5f765b58d84efe15accceff3fc162f9aa.png")
        #expect(R2IconUploader.objectKey(for: payload, ext: "jpg")
            == "db02ab6807f9ccbf6175e81ac44e12b5f765b58d84efe15accceff3fc162f9aa.jpg")
    }

    /// 三种扩展名各自显式映射；webp 从前只是兜底分支，认不出未知扩展名。
    @Test func contentTypeMapsEachExtensionExplicitly() {
        #expect(R2IconUploader.contentType(for: "a.png") == "image/png")
        #expect(R2IconUploader.contentType(for: "a.jpg") == "image/jpeg")
        #expect(R2IconUploader.contentType(for: "a.jpeg") == "image/jpeg")
        #expect(R2IconUploader.contentType(for: "a.webp") == "image/webp")
        #expect(R2IconUploader.contentType(for: "a.bin") == "application/octet-stream")
    }
}

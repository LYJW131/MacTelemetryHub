import Foundation

extension AppSettings {
    /**
     * 四项 R2 直传配置，缺一项或 endpoint 不是 https 就没有。
     *
     * 「配置从设置里怎么读」是 App 的事，签名和上传是纯逻辑（见 TelemetryCore
     * 的 `R2IconUploader`）。从前这段挂在 uploader 上，那个 enum 因此被
     * `@MainActor` 的 AppSettings 拽住，整块没法搬出去。
     */
    var r2UploadConfiguration: R2UploadConfiguration? {
        let endpointText = r2Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = r2Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKeyID = r2AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretAccessKey = r2SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointText.isEmpty, !bucket.isEmpty, !accessKeyID.isEmpty,
              !secretAccessKey.isEmpty,
              let endpoint = URL(string: endpointText),
              endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            return nil
        }
        return R2UploadConfiguration(
            endpoint: endpoint,
            bucket: bucket,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
    }
}

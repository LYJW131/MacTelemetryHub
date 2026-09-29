import Foundation

extension AppSettings {
    /**
     * 四项 R2 直传配置，缺一项或 endpoint 不是 https 就没有。
     *
     * App 读取设置，`TelemetryCore.R2IconUploader` 接受显式配置。
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

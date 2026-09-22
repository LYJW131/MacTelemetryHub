import Foundation

/// 假采集器用的 Python 解释器，默认 `/usr/bin/python3`。
/// GitHub 的 macOS runner 上那是 xcrun 的 shim：真 python 由它另起，shim 先退出、输出晚到，
/// 采集器退出后只再等 2 秒收管道，拿到的是空输出。CI 用 `TEST_PYTHON` 指到真解释器。
let testPython = ProcessInfo.processInfo.environment["TEST_PYTHON"] ?? "/usr/bin/python3"

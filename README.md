# bowatch

bopc watchd 的 iOS + watchOS 原生客户端骨架。

- 工程文件由 XcodeGen 从 project.yml 生成（CI 里跑 xcodegen generate）
- .github/workflows/build.yml：GitHub Actions macOS runner 上免签构建双端
- 签名/装真机需本地 Xcode + 免费 Apple ID（云端免签产物装不进设备）

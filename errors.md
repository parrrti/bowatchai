## build-ios.log
/Users/runner/work/bowatchai/bowatchai/Sources/Shared/API.swift:12:8: error: type 'MWState' does not conform to protocol 'Encodable'
/Users/runner/work/bowatchai/bowatchai/Sources/Shared/ChatEngine.swift:276:20: error: type 'ChatEngine.Cache' does not conform to protocol 'Encodable'
--- tail ---
    

SwiftCompile normal x86_64 Compiling\ CookieImage.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/CookieImage.swift (in target 'bowatch' from project 'bowatch')

SwiftCompile normal x86_64 /Users/runner/work/bowatchai/bowatchai/Sources/Shared/CookieImage.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftCompile normal arm64 Compiling\ ChatEngine.swift,\ ContentView.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/ChatEngine.swift /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
Command SwiftCompile failed with a nonzero exit code

** BUILD FAILED **


The following build commands failed:
	EmitSwiftModule normal arm64 (in target 'bowatch' from project 'bowatch')
	SwiftEmitModule normal arm64 Emitting\ module\ for\ bowatch (in target 'bowatch' from project 'bowatch')
	SwiftCompile normal arm64 Compiling\ ChatEngine.swift,\ ContentView.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/ChatEngine.swift /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
	Building project bowatch with scheme bowatch-iOS
(4 failures)

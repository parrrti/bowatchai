## build-ios.log
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:106:46: error: value of type 'String.Element' (aka 'Character') has no member 'capitalized'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:224:25: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
--- tail ---
SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/Shared/ChatEngine.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftDriverJobDiscovery normal x86_64 Compiling CookieImage.swift (in target 'bowatch' from project 'bowatch')

SwiftDriverJobDiscovery normal arm64 Compiling API.swift, BowatchApp.swift (in target 'bowatch' from project 'bowatch')

** BUILD FAILED **


The following build commands failed:
	SwiftCompile normal x86_64 /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
	SwiftCompile normal x86_64 Compiling\ ChatEngine.swift,\ ContentView.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/ChatEngine.swift /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
	Building project bowatch with scheme bowatch-iOS
(3 failures)

## build-ios.log
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:237:66: error: cannot find 'confirmCompact' in scope
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:253:66: error: cannot find '$confirmCompact' in scope
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:445:10: error: value of type 'some View' has no member 'glassEffectContainer'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:446:23: error: cannot infer contextual base in reference to member 'regular'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:446:37: error: cannot infer contextual base in reference to member 'rect'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:447:19: error: cannot infer contextual base in reference to member 'horizontal'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:448:19: error: cannot infer contextual base in reference to member 'vertical'
--- tail ---

SwiftCompile normal x86_64 Compiling\ ContentView.swift,\ CookieImage.swift /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/CookieImage.swift (in target 'bowatch' from project 'bowatch')
SwiftCompile normal x86_64 /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftCompile normal x86_64 /Users/runner/work/bowatchai/bowatchai/Sources/Shared/CookieImage.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftDriverJobDiscovery normal x86_64 Compiling API.swift, BowatchApp.swift, ChatEngine.swift (in target 'bowatch' from project 'bowatch')

** BUILD FAILED **


The following build commands failed:
	SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
	SwiftCompile normal arm64 Compiling\ ContentView.swift,\ CookieImage.swift /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/CookieImage.swift (in target 'bowatch' from project 'bowatch')
	Building project bowatch with scheme bowatch-iOS
(3 failures)

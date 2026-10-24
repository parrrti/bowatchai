## build-ios.log
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:447:10: error: value of type 'some View' has no member 'glassEffectContainer'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:448:23: error: cannot infer contextual base in reference to member 'regular'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:448:37: error: cannot infer contextual base in reference to member 'rect'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:449:19: error: cannot infer contextual base in reference to member 'horizontal'
/Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift:450:19: error: cannot infer contextual base in reference to member 'vertical'
--- tail ---
SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/Shared/API.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/iOS/BowatchApp.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/Shared/ChatEngine.swift (in target 'bowatch' from project 'bowatch')
    cd /Users/runner/work/bowatchai/bowatchai
    

** BUILD FAILED **


The following build commands failed:
	SwiftCompile normal arm64 /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift (in target 'bowatch' from project 'bowatch')
	SwiftCompile normal arm64 Compiling\ ContentView.swift,\ CookieImage.swift /Users/runner/work/bowatchai/bowatchai/Sources/iOS/ContentView.swift /Users/runner/work/bowatchai/bowatchai/Sources/Shared/CookieImage.swift (in target 'bowatch' from project 'bowatch')
	Building project bowatch with scheme bowatch-iOS
(3 failures)

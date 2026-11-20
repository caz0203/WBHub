# CI build errors

```
xcodebuild: error: Unable to read project 'WBHub.xcodeproj'.
```

## tail 120
```
Command line invocation:
    /Applications/Xcode_26.6.app/Contents/Developer/usr/bin/xcodebuild -project WBHub.xcodeproj -scheme WBHub -configuration Release -sdk iphoneos -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS= build

Build settings from command line:
    ARCHS = arm64
    CODE_SIGN_ENTITLEMENTS = 
    CODE_SIGN_IDENTITY = 
    CODE_SIGNING_ALLOWED = NO
    CODE_SIGNING_REQUIRED = NO
    ONLY_ACTIVE_ARCH = NO
    SDKROOT = iphoneos26.5

2026-11-20 03:41:15.443 xcodebuild[1937:9628] Error Domain=NSCocoaErrorDomain Code=3840 "JSON text did not start with array or object and option to allow fragments not set. around line 1, column 0." UserInfo={NSDebugDescription=JSON text did not start with array or object and option to allow fragments not set. around line 1, column 0., NSJSONSerializationErrorIndex=0}
2026-11-20 03:41:15.447 xcodebuild[1937:9628] Writing error result bundle to /var/folders/h5/t85nd63d71x27_8gl5gw3l_w0000gn/T/ResultBundle_2026-20-11_03-41-0015.xcresult
xcodebuild: error: Unable to read project 'WBHub.xcodeproj'.
	Reason: The project ‘WBHub’ is damaged and cannot be opened due to a parse error. Examine the project file for invalid edits or unresolved source control conflicts.

Path: /Users/runner/work/WBHub/WBHub/WBHub.xcodeproj


```

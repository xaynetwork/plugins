// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FlutterWebView.h"
#import "FLTWKNavigationDelegate.h"
#import "FLTWKProgressionDelegate.h"
#import "JavaScriptChannelHandler.h"
#import "WebViewManager.h"
#if __has_include("webview_flutter-Swift.h")
#import <webview_flutter-Swift.h>
#else
#import <webview_flutter/webview_flutter-Swift.h>
#endif

@implementation FLTWebViewFactory {
  NSObject<FlutterBinaryMessenger>* _messenger;
  NSObject<FlutterPluginRegistrar>* _registrar;
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  if (self) {
    _registrar = registrar;
    _messenger = registrar.messenger;
  }
  return self;
}

- (NSObject<FlutterMessageCodec>*)createArgsCodec {
  return [FlutterStandardMessageCodec sharedInstance];
}

- (NSObject<FlutterPlatformView>*)createWithFrame:(CGRect)frame
                                   viewIdentifier:(int64_t)viewId
                                        arguments:(id _Nullable)args {
  FLTWebViewController* webviewController = [[FLTWebViewController alloc] initWithFrame:frame
                                                                         viewIdentifier:viewId
                                                                              arguments:args
                                                                        registrar:_registrar];
  return webviewController;
}

@end

@implementation FLTWKWebView

- (void)setFrame:(CGRect)frame {
  [super setFrame:frame];
  self.scrollView.contentInset = UIEdgeInsetsZero;
  // We don't want the contentInsets to be adjusted by iOS, flutter should always take control of
  // webview's contentInsets.
  // self.scrollView.contentInset = UIEdgeInsetsZero;
  if (@available(iOS 11, *)) {
    // Above iOS 11, adjust contentInset to compensate the adjustedContentInset so the sum will
    // always be 0.
    if (UIEdgeInsetsEqualToEdgeInsets(self.scrollView.adjustedContentInset, UIEdgeInsetsZero)) {
      return;
    }
    UIEdgeInsets insetToAdjust = self.scrollView.adjustedContentInset;
    self.scrollView.contentInset = UIEdgeInsetsMake(-insetToAdjust.top, -insetToAdjust.left,
                                                    -insetToAdjust.bottom, -insetToAdjust.right);
  }
}

@end

@implementation FLTWebViewController {
  FLTWKWebView* _webView;
  int64_t _viewId;
  FlutterMethodChannel* _channel;
  NSString* _currentUrl;
  // The set of registered JavaScript channel names.
  NSMutableSet* _javaScriptChannelNames;
  FLTWKNavigationDelegate* _navigationDelegate;
  NSObject<FlutterPluginRegistrar>* _registrar;
  FLTWKProgressionDelegate* _progressionDelegate;
}

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
              registrar:(nonnull NSObject<FlutterPluginRegistrar>*)registrar {
  if (self = [super init]) {
    _viewId = viewId;

    _registrar = registrar;
    NSString* channelName = [NSString stringWithFormat:@"plugins.flutter.io/webview_%lld", viewId];
    _channel = [FlutterMethodChannel methodChannelWithName:channelName
                                           binaryMessenger:_registrar.messenger];
    _javaScriptChannelNames = [[NSMutableSet alloc] init];

    WKUserContentController* userContentController = [[WKUserContentController alloc] init];
    if ([args[@"javascriptChannelNames"] isKindOfClass:[NSArray class]]) {
      NSArray* javaScriptChannelNames = args[@"javascriptChannelNames"];
      [_javaScriptChannelNames addObjectsFromArray:javaScriptChannelNames];
      [self registerJavaScriptChannels:_javaScriptChannelNames controller:userContentController];
    }

    NSDictionary<NSString*, id>* settings = args[@"settings"];

    WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
    configuration.userContentController = userContentController;
    [self updateAutoMediaPlaybackPolicy:args[@"autoMediaPlaybackPolicy"]
                        inConfiguration:configuration];

    WebViewManager *webViewManager = [WebViewManager sharedManager];

    if ([args[@"maxCachedTabs"] isKindOfClass:[NSNumber class]]) {
        NSNumber *maxCachedTabs = args[@"maxCachedTabs"];
        [webViewManager updateMaxCachedTabs:maxCachedTabs];
    }
      
    if ([args[@"tabId"] isKindOfClass:[NSString class]]) {
        NSString *tabId = args[@"tabId"];
        _webView = [webViewManager webViewForId:tabId];
    }
    
    BOOL shouldLoad = NO;
    if (!_webView) {
        _webView = [[FLTWKWebView alloc] initWithFrame:frame configuration:configuration];
        shouldLoad = YES;

        if ([args[@"tabId"] isKindOfClass:[NSString class]]) {
            NSString *tabId = args[@"tabId"];
            [webViewManager cacheWebView:_webView forId:tabId];
        }
    }
      
    _navigationDelegate = [[FLTWKNavigationDelegate alloc] initWithChannel:_channel];
    _webView.UIDelegate = self;
    _webView.navigationDelegate = _navigationDelegate;
    __weak __typeof__(self) weakSelf = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
      [weakSelf onMethodCall:call result:result];
    }];

    if (@available(iOS 11.0, *)) {
      _webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
      if (@available(iOS 13.0, *)) {
        _webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
      }
    }

    [self applySettings:settings];
    // TODO(amirh): return an error if apply settings failed once it's possible to do so.
    // https://github.com/flutter/flutter/issues/36228

    void (^loadBlock)(void) = ^{
      NSString* initialUrl = args[@"initialUrl"];
      if ([initialUrl isKindOfClass:[NSString class]] && shouldLoad) {
        [self loadUrl:initialUrl];
      }
    };

    if ([args[@"blockingRules"] isKindOfClass:[NSDictionary class]]) {
      NSDictionary *rules = args[@"blockingRules"];
      [ContentBlocker.shared setupContentBlockingWithRules:rules webview:_webView completion:loadBlock];
    } else {
      loadBlock();
    }
  }
  return self;
}

- (void)dealloc {
  if (_progressionDelegate != nil) {
    [_progressionDelegate stopObservingProgress:_webView];
  }
}

- (UIView*)view {
  return _webView;
}

- (void)onMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([[call method] isEqualToString:@"updateSettings"]) {
    [self onUpdateSettings:call result:result];
  } else if ([[call method] isEqualToString:@"loadUrl"]) {
    [self onLoadUrl:call result:result];
  } else if ([[call method] isEqualToString:@"loadAssetHtmlFile"]) {
    [self onLoadAssetHtmlFile:call result:result];
  } else if ([[call method] isEqualToString:@"loadLocalHtmlFile"]) {
    [self onLoadLocalHtmlFile:call result:result];
  } else if ([[call method] isEqualToString:@"canGoBack"]) {
    [self onCanGoBack:call result:result];
  } else if ([[call method] isEqualToString:@"canGoForward"]) {
    [self onCanGoForward:call result:result];
  } else if ([[call method] isEqualToString:@"goBack"]) {
    [self onGoBack:call result:result];
  } else if ([[call method] isEqualToString:@"goForward"]) {
    [self onGoForward:call result:result];
  } else if ([[call method] isEqualToString:@"reload"]) {
    [self onReload:call result:result];
  } else if ([[call method] isEqualToString:@"currentUrl"]) {
    [self onCurrentUrl:call result:result];
  } else if ([[call method] isEqualToString:@"evaluateJavascript"]) {
    [self onEvaluateJavaScript:call result:result];
  } else if ([[call method] isEqualToString:@"addJavascriptChannels"]) {
    [self onAddJavaScriptChannels:call result:result];
  } else if ([[call method] isEqualToString:@"removeJavascriptChannels"]) {
    [self onRemoveJavaScriptChannels:call result:result];
  } else if ([[call method] isEqualToString:@"clearCache"]) {
    [self clearCache:result];
  } else if ([[call method] isEqualToString:@"getTitle"]) {
    [self onGetTitle:result];
  } else if ([[call method] isEqualToString:@"scrollTo"]) {
    [self onScrollTo:call result:result];
  } else if ([[call method] isEqualToString:@"scrollBy"]) {
    [self onScrollBy:call result:result];
  } else if ([[call method] isEqualToString:@"getScrollX"]) {
    [self getScrollX:call result:result];
  } else if ([[call method] isEqualToString:@"getScrollY"]) {
    [self getScrollY:call result:result];
  } else if ([[call method] isEqualToString:@"takeScreenshot"]) {
    [self takeScreenshot:call result:result];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)onUpdateSettings:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* error = [self applySettings:[call arguments]];
  if (error == nil) {
    result(nil);
    return;
  }
  result([FlutterError errorWithCode:@"updateSettings_failed" message:error details:nil]);
}

- (void)setupContentBlockers:(NSArray<NSString *> *)hosts completion:(void (^)(void))completion {
    
    if ([hosts count] == 0) {
        completion();
        return;
    }
    NSString *contentBlockersIdentifier = @"contentBlockersIdentifier";
    NSString *jsonStringFormat = @"[{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[%@]},\"action\":{\"type\":\"block\"}}]";
    
    NSMutableArray<NSString *> *formattedHosts = [NSMutableArray arrayWithCapacity:[hosts count]];
    [hosts enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [formattedHosts addObject:[NSString stringWithFormat:@"\"%@\"", obj]];
    }];
    
    NSString *hostsString = [formattedHosts componentsJoinedByString:@","];
    NSString *jsonString = [NSString stringWithFormat:jsonStringFormat, hostsString];

    if (@available(iOS 11.0, *)) {
        [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:contentBlockersIdentifier encodedContentRuleList:jsonString completionHandler:^(WKContentRuleList *list, NSError *error) {
            
            if (error) {
                completion();
                return;
            }
            
            [[self->_webView configuration].userContentController addContentRuleList: list];
            completion();
        }];
    } else {
        completion();
    }
}

- (void)onLoadUrl:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (![self loadRequest:[call arguments]]) {
    result([FlutterError
        errorWithCode:@"loadUrl_failed"
              message:@"Failed parsing the URL"
              details:[NSString stringWithFormat:@"Request was: '%@'", [call arguments]]]);
  } else {
    result(nil);
  }
}

- (void)onLoadAssetHtmlFile:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* url = [call arguments];
  if (![self loadAssetHtmlFile:url]) {
    result([FlutterError errorWithCode:@"loadAssetHtmlFile_failed"
                               message:@"Failed parsing the URL"
                               details:[NSString stringWithFormat:@"URL was: '%@'", url]]);
  } else {
    result(nil);
  }
}

- (void)onLoadLocalHtmlFile:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* url = [call arguments];
  if (![self loadLocalHtmlFile:url]) {
    result([FlutterError errorWithCode:@"loadAssetHtmlFile_failed"
                               message:@"Failed parsing the URL"
                               details:[NSString stringWithFormat:@"URL was: '%@'", url]]);
  } else {
    result(nil);
  }
}


- (void)onCanGoBack:(FlutterMethodCall*)call result:(FlutterResult)result {
  BOOL canGoBack = [_webView canGoBack];
  result([NSNumber numberWithBool:canGoBack]);
}

- (void)onCanGoForward:(FlutterMethodCall*)call result:(FlutterResult)result {
  BOOL canGoForward = [_webView canGoForward];
  result([NSNumber numberWithBool:canGoForward]);
}

- (void)onGoBack:(FlutterMethodCall*)call result:(FlutterResult)result {
  [_webView goBack];
  result(nil);
}

- (void)onGoForward:(FlutterMethodCall*)call result:(FlutterResult)result {
  [_webView goForward];
  result(nil);
}

- (void)onReload:(FlutterMethodCall*)call result:(FlutterResult)result {
  [_webView reload];
  result(nil);
}

- (void)onCurrentUrl:(FlutterMethodCall*)call result:(FlutterResult)result {
  _currentUrl = [[_webView URL] absoluteString];
  result(_currentUrl);
}

- (void)onEvaluateJavaScript:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* jsString = [call arguments];
  if (!jsString) {
    result([FlutterError errorWithCode:@"evaluateJavaScript_failed"
                               message:@"JavaScript String cannot be null"
                               details:nil]);
    return;
  }
  [_webView evaluateJavaScript:jsString
             completionHandler:^(_Nullable id evaluateResult, NSError* _Nullable error) {
               if (error) {
                 result([FlutterError
                     errorWithCode:@"evaluateJavaScript_failed"
                           message:@"Failed evaluating JavaScript"
                           details:[NSString stringWithFormat:@"JavaScript string was: '%@'\n%@",
                                                              jsString, error]]);
               } else {
                 result([NSString stringWithFormat:@"%@", evaluateResult]);
               }
             }];
}

- (void)onAddJavaScriptChannels:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSArray* channelNames = [call arguments];
  NSSet* channelNamesSet = [[NSSet alloc] initWithArray:channelNames];
  [_javaScriptChannelNames addObjectsFromArray:channelNames];
  [self registerJavaScriptChannels:channelNamesSet
                        controller:_webView.configuration.userContentController];
  result(nil);
}

- (void)onRemoveJavaScriptChannels:(FlutterMethodCall*)call result:(FlutterResult)result {
  // WkWebView does not support removing a single user script, so instead we remove all
  // user scripts, all message handlers. And re-register channels that shouldn't be removed.
  [_webView.configuration.userContentController removeAllUserScripts];
  for (NSString* channelName in _javaScriptChannelNames) {
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:channelName];
  }

  NSArray* channelNamesToRemove = [call arguments];
  for (NSString* channelName in channelNamesToRemove) {
    [_javaScriptChannelNames removeObject:channelName];
  }

  [self registerJavaScriptChannels:_javaScriptChannelNames
                        controller:_webView.configuration.userContentController];
  result(nil);
}

- (void)clearCache:(FlutterResult)result {
  if (@available(iOS 9.0, *)) {
    NSSet* cacheDataTypes = [WKWebsiteDataStore allWebsiteDataTypes];
    WKWebsiteDataStore* dataStore = [WKWebsiteDataStore defaultDataStore];
    NSDate* dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
    [dataStore removeDataOfTypes:cacheDataTypes
                   modifiedSince:dateFrom
               completionHandler:^{
                 result(nil);
               }];
  } else {
    // support for iOS8 tracked in https://github.com/flutter/flutter/issues/27624.
    NSLog(@"Clearing cache is not supported for Flutter WebViews prior to iOS 9.");
  }
}

- (void)onGetTitle:(FlutterResult)result {
  NSString* title = _webView.title;
  result(title);
}

- (void)onScrollTo:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary* arguments = [call arguments];
  int x = [arguments[@"x"] intValue];
  int y = [arguments[@"y"] intValue];

  _webView.scrollView.contentOffset = CGPointMake(x, y);
  result(nil);
}

- (void)onScrollBy:(FlutterMethodCall*)call result:(FlutterResult)result {
  CGPoint contentOffset = _webView.scrollView.contentOffset;

  NSDictionary* arguments = [call arguments];
  int x = [arguments[@"x"] intValue] + contentOffset.x;
  int y = [arguments[@"y"] intValue] + contentOffset.y;

  _webView.scrollView.contentOffset = CGPointMake(x, y);
  result(nil);
}

- (void)getScrollX:(FlutterMethodCall*)call result:(FlutterResult)result {
  int offsetX = _webView.scrollView.contentOffset.x;
  result([NSNumber numberWithInt:offsetX]);
}

- (void)getScrollY:(FlutterMethodCall*)call result:(FlutterResult)result {
  int offsetY = _webView.scrollView.contentOffset.y;
  result([NSNumber numberWithInt:offsetY]);
}

- (void)takeScreenshot:(FlutterMethodCall*)call result:(FlutterResult)result{
  [_webView takeSnapshotWithConfiguration:nil 
        completionHandler:^(UIImage *snapshotImage, NSError *error){
        NSData *imageData = UIImagePNGRepresentation(snapshotImage);
        result(imageData);
  }];
}

// Returns nil when successful, or an error message when one or more keys are unknown.
- (NSString*)applySettings:(NSDictionary<NSString*, id>*)settings {
  NSMutableArray<NSString*>* unknownKeys = [[NSMutableArray alloc] init];
  for (NSString* key in settings) {
    if ([key isEqualToString:@"jsMode"]) {
      NSNumber* mode = settings[key];
      [self updateJsMode:mode];
    } else if ([key isEqualToString:@"hasNavigationDelegate"]) {
      NSNumber* hasDartNavigationDelegate = settings[key];
      _navigationDelegate.hasDartNavigationDelegate = [hasDartNavigationDelegate boolValue];
    } else if ([key isEqualToString:@"hasProgressTracking"]) {
      NSNumber* hasProgressTrackingValue = settings[key];
      bool hasProgressTracking = [hasProgressTrackingValue boolValue];
      if (hasProgressTracking) {
        _progressionDelegate = [[FLTWKProgressionDelegate alloc] initWithWebView:_webView
                                                                         channel:_channel];
      }
    } else if ([key isEqualToString:@"debuggingEnabled"]) {
      // no-op debugging is always enabled on iOS.
    } else if ([key isEqualToString:@"gestureNavigationEnabled"]) {
      NSNumber* allowsBackForwardNavigationGestures = settings[key];
      _webView.allowsBackForwardNavigationGestures =
          [allowsBackForwardNavigationGestures boolValue];
    } else if ([key isEqualToString:@"userAgent"]) {
      NSString* userAgent = settings[key];
      [self updateUserAgent:[userAgent isEqual:[NSNull null]] ? nil : userAgent];
    } else if ([key isEqualToString:@"allowsInlineMediaPlayback"]) {
      NSNumber* allowsInlineMediaPlayback = settings[key];
      _webView.configuration.allowsInlineMediaPlayback = [allowsInlineMediaPlayback boolValue];
    } else {
      [unknownKeys addObject:key];
    }
  }
  if ([unknownKeys count] == 0) {
    return nil;
  }
  return [NSString stringWithFormat:@"webview_flutter: unknown setting keys: {%@}",
                                    [unknownKeys componentsJoinedByString:@", "]];
}

- (void)updateJsMode:(NSNumber*)mode {
  WKPreferences* preferences = [[_webView configuration] preferences];
  switch ([mode integerValue]) {
    case 0:  // disabled
      [preferences setJavaScriptEnabled:NO];
      break;
    case 1:  // unrestricted
      [preferences setJavaScriptEnabled:YES];
      break;
    default:
      NSLog(@"webview_flutter: unknown JavaScript mode: %@", mode);
  }
}

- (void)updateAutoMediaPlaybackPolicy:(NSNumber*)policy
                      inConfiguration:(WKWebViewConfiguration*)configuration {
  switch ([policy integerValue]) {
    case 0:  // require_user_action_for_all_media_types
      if (@available(iOS 10.0, *)) {
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
      } else {
        configuration.mediaPlaybackRequiresUserAction = true;
      }
      break;
    case 1:  // always_allow
      if (@available(iOS 10.0, *)) {
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
      } else {
        configuration.mediaPlaybackRequiresUserAction = false;
      }
      break;
    default:
      NSLog(@"webview_flutter: unknown auto media playback policy: %@", policy);
  }
}

- (bool)loadRequest:(NSDictionary<NSString*, id>*)request {
  if (!request) {
    return false;
  }

  NSString* url = request[@"url"];
  if ([url isKindOfClass:[NSString class]]) {
    id headers = request[@"headers"];
    if ([headers isKindOfClass:[NSDictionary class]]) {
      return [self loadUrl:url withHeaders:headers];
    } else {
      return [self loadUrl:url];
    }
  }

  return false;
}

- (bool)loadUrl:(NSString*)url {
  return [self loadUrl:url withHeaders:[NSMutableDictionary dictionary]];
}

- (bool)loadUrl:(NSString*)url withHeaders:(NSDictionary<NSString*, NSString*>*)headers {
  NSURL* nsUrl = [NSURL URLWithString:url];
  if (!nsUrl) {
    return false;
  }
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:nsUrl];
  [request setAllHTTPHeaderFields:headers];
  [_webView loadRequest:request];
  return true;
}

- (BOOL)loadAssetHtmlFile:(NSString*)url {
  NSArray* array = [url componentsSeparatedByString:@"?"];
  NSString* pathString = [array objectAtIndex:0];
  NSString* key = [_registrar lookupKeyForAsset:pathString];
  NSURL* baseURL = [[NSBundle mainBundle] URLForResource:key withExtension:nil];
  if (!baseURL) {
    return NO;
  }
  NSURL* newUrl = baseURL;
  if ([array count] > 1) {
    NSString* queryString = [array objectAtIndex:1];
    NSString* queryPart = [NSString stringWithFormat:@"%@%@", @"?", queryString];
    newUrl = [NSURL URLWithString:queryPart relativeToURL:baseURL];
  }
  if (@available(iOS 9.0, *)) {
    [_webView loadFileURL:newUrl allowingReadAccessToURL:[NSURL URLWithString:@"file:///"]];
  } else {
    return NO;
  }
  return YES;
}

- (BOOL)loadLocalHtmlFile:(NSString*)url {
  NSArray* array = [url componentsSeparatedByString:@"?"];
  NSString* pathString = [array objectAtIndex:0];
  NSString* key = [_registrar lookupKeyForAsset:pathString];
  NSURL* baseURL = [[NSBundle mainBundle] URLForResource:key withExtension:nil];
  if (!baseURL) {
    [_webView loadFileURL:[NSURL fileURLWithPath:pathString]
        allowingReadAccessToURL:[NSURL fileURLWithPath:pathString]];
    return YES;
  }
  NSURL* newUrl = baseURL;
  if ([array count] > 1) {
    NSString* queryString = [array objectAtIndex:1];
    NSString* queryPart = [NSString stringWithFormat:@"%@%@", @"?", queryString];
    newUrl = [NSURL URLWithString:queryPart relativeToURL:baseURL];
  }
  if (@available(iOS 9.0, *)) {
    [_webView loadFileURL:newUrl allowingReadAccessToURL:[NSURL URLWithString:@"file:///"]];
  } else {
    return NO;
  }
  return YES;
}

- (void)registerJavaScriptChannels:(NSSet*)channelNames
                        controller:(WKUserContentController*)userContentController {
  for (NSString* channelName in channelNames) {
    FLTJavaScriptChannel* channel =
        [[FLTJavaScriptChannel alloc] initWithMethodChannel:_channel
                                      javaScriptChannelName:channelName];
    [userContentController addScriptMessageHandler:channel name:channelName];
    NSString* wrapperSource = [NSString
        stringWithFormat:@"window.%@ = webkit.messageHandlers.%@;", channelName, channelName];
    WKUserScript* wrapperScript =
        [[WKUserScript alloc] initWithSource:wrapperSource
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:NO];
    [userContentController addUserScript:wrapperScript];
  }
}

- (void)updateUserAgent:(NSString*)userAgent {
  if (@available(iOS 9.0, *)) {
    [_webView setCustomUserAgent:userAgent];
  } else {
    NSLog(@"Updating UserAgent is not supported for Flutter WebViews prior to iOS 9.");
  }
}

#pragma mark WKUIDelegate

- (WKWebView*)webView:(WKWebView*)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration*)configuration
               forNavigationAction:(WKNavigationAction*)navigationAction
                    windowFeatures:(WKWindowFeatures*)windowFeatures {
  if (!navigationAction.targetFrame.isMainFrame) {
    [webView loadRequest:navigationAction.request];
  }

  return nil;
}

@end

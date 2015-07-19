/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "AppDelegate.h"

#import "RCTRootView.h"
#import "RCTEventDispatcher.h"
#import "ABYServer.h"
#import "ABYContextManager.h"
#import "BTHContextExecutor.h"

@interface AppDelegate()

@property (strong, nonatomic) ABYServer* replServer;
@property (strong, nonatomic) ABYContextManager* contextManager;
@property (strong, nonatomic) NSURL* compilerOutputDirectory;

@end

@implementation AppDelegate

-(void)requireAppNamespaces:(JSContext*)context
{
  [context evaluateScript:@"goog.require('qttt.ui.om_ios');"];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  NSURL *jsCodeLocation;

  /**
   * Loading JavaScript code - uncomment the one you want.
   *
   * OPTION 1
   * Load from development server. Start the server from the repository root:
   *
   * $ npm start
   *
   * To run on device, change `localhost` to the IP address of your computer
   * (you can get this by typing `ifconfig` into the terminal and selecting the
   * `inet` value under `en0:`) and make sure your computer and iOS device are
   * on the same Wi-Fi network.
   */

  //jsCodeLocation = [NSURL URLWithString:@"http://localhost:8081/index.ios.bundle"];

  /**
   * OPTION 2
   * Load from pre-bundled file on disk. To re-generate the static bundle
   * from the root of your project directory, run
   *
   * $ react-native bundle --minify
   *
   * see http://facebook.github.io/react-native/docs/runningondevice.html
   */

   jsCodeLocation = [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];

  //RCTRootView *rootView = [[RCTRootView alloc] initWithBundleURL:jsCodeLocation
  //                                                    moduleName:@"QTTT"
  //                                                 launchOptions:launchOptions];
  
  // Set up the compiler output directory
  self.compilerOutputDirectory = [[self privateDocumentsDirectory] URLByAppendingPathComponent:@"cljs-out"];
  
  // Set up our context
  self.contextManager = [[ABYContextManager alloc] initWithContext:JSGlobalContextCreate(NULL)
                                           compilerOutputDirectory:self.compilerOutputDirectory];
 
  
  // Inject our context into the BTHContextExecutor (it sets the static variable)
  [BTHContextExecutor setContext:self.contextManager.context];
  
  // Set React Native to intstantiate our BTHContextExecutor, doing this by slipping the executorClass
  // assignement between alloc and initWithBundleURL:moduleProvider:launchOptions:
  RCTBridge *bridge = [RCTBridge alloc];
  bridge.executorClass = [BTHContextExecutor class];
  bridge = [bridge initWithBundleURL:jsCodeLocation
                      moduleProvider:nil
                       launchOptions:launchOptions];
  
  // Set up a root view using the bridge defined above
  RCTRootView *rootView = [[RCTRootView alloc] initWithBridge:bridge
                                                   moduleName:@"QTTT"];
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(contentDidAppear)
                                               name:RCTContentDidAppearNotification
                                             object:rootView];
  
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  UIViewController *rootViewController = [[UIViewController alloc] init];
  rootViewController.view = rootView;
  self.window.rootViewController = rootViewController;
  [self.window makeKeyAndVisible];
  
  return YES;
}

- (void)contentDidAppear
{
  // Ensure private documents directory exists
  [self createDirectoriesUpTo:[self privateDocumentsDirectory]];
  
  // Copy resources from bundle "out" to compilerOutputDirectory
  
  NSFileManager* fileManager = [NSFileManager defaultManager];
  fileManager.delegate = self;
  
  // First blow away old compiler output directory
  [fileManager removeItemAtPath:self.compilerOutputDirectory.path error:nil];
  
  // Copy files from bundle to compiler output driectory
  NSString *outPath = [[NSBundle mainBundle] pathForResource:@"out" ofType:nil];
  [fileManager copyItemAtPath:outPath toPath:self.compilerOutputDirectory.path error:nil];
  
   [self.contextManager setUpAmblyImportScript];
  
  NSString* mainJsFilePath = [[self.compilerOutputDirectory URLByAppendingPathComponent:@"main" isDirectory:NO] URLByAppendingPathExtension:@"js"].path;
  
  NSURL* googDirectory = [self.compilerOutputDirectory URLByAppendingPathComponent:@"goog"];
  
  [self.contextManager bootstrapWithDepsFilePath:mainJsFilePath
                                    googBasePath:[[googDirectory URLByAppendingPathComponent:@"base" isDirectory:NO] URLByAppendingPathExtension:@"js"].path];
  
  JSContext* context = [JSContext contextWithJSGlobalContextRef:self.contextManager.context];
  [self requireAppNamespaces:context];
  
  JSValue* initFn = [self getValue:@"main" inNamespace:@"qttt.ui.om-ios" fromContext:context];
  NSAssert(!initFn.isUndefined, @"Could not find the app init function");
  [initFn callWithArguments:@[]];
  
  // Send a nonsense UI event to get the UI going
  RCTRootView* rootView = (RCTRootView*)self.window.rootViewController.view;
  [rootView.bridge.modules[@"RCTEventDispatcher"] sendInputEventWithName:@"" body:@{@"target": @1}];
  
  // Now that React Native has been initialized, fire up our REPL server
  self.replServer = [[ABYServer alloc] initWithContext:self.contextManager.context
                               compilerOutputDirectory:self.compilerOutputDirectory];
  BOOL successful = [self.replServer startListening];
  if (!successful) {
    NSLog(@"Failed to start REPL server.");
  }


}

- (NSURL *)privateDocumentsDirectory
{
  NSURL *libraryDirectory = [[[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] lastObject];
  
  return [libraryDirectory URLByAppendingPathComponent:@"Private Documents"];
}

- (void)createDirectoriesUpTo:(NSURL*)directory
{
  if (![[NSFileManager defaultManager] fileExistsAtPath:[directory path]]) {
    NSError *error = nil;
    
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[directory path]
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
      NSLog(@"Can't create directory %@ [%@]", [directory path], error);
      abort();
    }
  }
}

- (JSValue*)getValue:(NSString*)name inNamespace:(NSString*)namespace fromContext:(JSContext*)context
{
  JSValue* namespaceValue = nil;
  for (NSString* namespaceElement in [namespace componentsSeparatedByString: @"."]) {
    if (namespaceValue) {
      namespaceValue = namespaceValue[[self munge:namespaceElement]];
    } else {
      namespaceValue = context[[self munge:namespaceElement]];
    }
  }
  
  return namespaceValue[[self munge:name]];
}

- (NSString*)munge:(NSString*)s
{
  return [[[s stringByReplacingOccurrencesOfString:@"-" withString:@"_"]
           stringByReplacingOccurrencesOfString:@"!" withString:@"_BANG_"]
          stringByReplacingOccurrencesOfString:@"?" withString:@"_QMARK_"];
}

@end

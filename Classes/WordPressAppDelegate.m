#import "WordPressAppDelegate.h"
#import "Reachability.h"
#import "NSString+Helpers.h"
#import "CPopoverManager.h"
//#import "UIViewController_iPadExtensions.h"
#import "BetaUIWindow.h"
#import "MigrateBlogsFromFiles.h"
//#import "InAppSettings.h"
#import "Blog.h"
#import "Media.h"
#import "SFHFKeychainUtils.h"
#import "CameraPlusPickerManager.h"
#import "PanelNavigationController.h"
#import "SidebarViewController.h"

@interface WordPressAppDelegate (Private)
- (void)setAppBadge;
- (void)checkIfStatsShouldRun;
- (void)runStats;
- (void)showPasswordAlert;
- (void)cleanUnusedMediaFileFromTmpDir;
@end

NSString *CrashFilePath() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    return [documentsDirectory stringByAppendingPathComponent:@"crash_data.txt"];
}

@implementation WordPressAppDelegate

static WordPressAppDelegate *wordPressApp = NULL;

@synthesize window, currentBlog, postID;
@synthesize navigationController, alertRunning, isWPcomAuthenticated;
@synthesize crashReportView, isUploadingPost;
@synthesize connectionAvailable, wpcomAvailable, currentBlogAvailable, wpcomReachability, internetReachability, currentBlogReachability;
@synthesize facebook;
@synthesize panelNavigationController;

#pragma mark -
#pragma mark Class Methods

+ (WordPressAppDelegate *)sharedWordPressApp {
    if (!wordPressApp) {
        wordPressApp = [[WordPressAppDelegate alloc] init];
    }

    return wordPressApp;
}

#pragma mark -
#pragma mark LifeCycle Methods

- (void)dealloc {
	[crashReportView release];
	[postID release];
    [navigationController release];
    [window release];
	[currentBlog release];
    [passwordTextField release];
    [wpcomReachability release];
    [internetReachability release];
    [facebook release];
    [panelNavigationController release];
    [managedObjectModel_ release];
    [managedObjectContext_ release];
    
    [super dealloc];
}

- (id)init {
    [FileLogger log:@"%@ %@", self, NSStringFromSelector(_cmd)];
    if (!wordPressApp) {
        wordPressApp = [super init];
		
//		if (DeviceIsPad())
//			[UIViewController youWillAutorotateOrYouWillDieMrBond];
        
		if([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_authenticated_flag"] != nil) {
			NSString *tempIsAuthenticated = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_authenticated_flag"];
			if([tempIsAuthenticated isEqualToString:@"1"])
				self.isWPcomAuthenticated = YES;
		}
		
		NSString *appVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
		[[NSUserDefaults standardUserDefaults] setObject:appVersion forKey:@"version_preference"];
        NSString *defaultUA = [NSString stringWithFormat:@"wp-iphone/%@ (%@ %@, %@)", 
                               appVersion,
                               [[UIDevice currentDevice] systemName], 
                               [[UIDevice currentDevice] systemVersion], 
                               [[UIDevice currentDevice] model]
                               ];
        
        NSDictionary *dictionary = [[NSDictionary alloc] initWithObjectsAndKeys: defaultUA, @"UserAgent", nil];
        [[NSUserDefaults standardUserDefaults] registerDefaults:dictionary];
        [dictionary release];
        
        self.wpcomAvailable = YES; //Set the wpcom availability to YES to avoid issues with lazy reachibility notifier        
        
        /* 
         ( The following "init" code loads the Settings.bundle at startup and it is required from InAppSettings. 
         We are not using it since at this point the app already loaded the bundle. Keep the code for future reference. )
         
         //The user defaults from the Settings.bundle are not initialized on startup, and are only initialized when viewed in the Settings App. 
         //InAppSettings has a registerDefaults class method that can be called to initialize all of the user defaults from the Settings.bundle. 
         if([self class] == [WordPressAppDelegate class]){
         [InAppSettings registerDefaults];
         }
         */
    }
    
    return wordPressApp;
}


#pragma mark -
#pragma mark UIApplicationDelegate Methods

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {    

#ifdef DEBUG
    WPFLog(@"Notifications: sandbox");
#else
    WPFLog(@"Notifications: production");
#endif
    	
	if(getenv("NSZombieEnabled"))
		NSLog(@"NSZombieEnabled!");
	else if(getenv("NSAutoreleaseFreedObjectCheckEnabled"))
		NSLog(@"NSAutoreleaseFreedObjectCheckEnabled enabled!");

	// Set current directory for WordPress app
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *currentDirectoryPath = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wordpress"];
	
	BOOL isDir;
	
	if (![fileManager fileExistsAtPath:currentDirectoryPath isDirectory:&isDir] || !isDir) {
		[fileManager createDirectoryAtPath:currentDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
	}
    
	//FIXME: we should handle errors here:
	/*
	 NSError *error;
	 BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:currentDirectoryPath withIntermediateDirectories:YES attributes:nil error:&error];
	 if (!success) {
	 NSLog(@"Error creating data path: %@", [error localizedDescription]);
	 }
	 */
	
	// set the current dir
	[fileManager changeCurrentDirectoryPath:currentDirectoryPath];
    
	// Check for pending crash reports
	PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
	if (![crashReporter hasPendingCrashReport]) {
        // Empty log file if we didn't crash last time
        [[FileLogger sharedInstance] reset];
    }
	[FileLogger log:@"Launching WordPress for iOS %@...", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]];
    [FileLogger log:@"device: %@, iOS %@", [[UIDevice currentDevice] platform], [[UIDevice currentDevice] systemVersion]];

    [[AFNetworkActivityIndicatorManager sharedManager] setEnabled:YES];
    // allocate the internet reachability object
    internetReachability = [Reachability reachabilityForInternetConnection];
    
    self.connectionAvailable = [internetReachability isReachable];
    // set the blocks 
    internetReachability.reachableBlock = ^(Reachability*reach)
    {  
        WPLog(@"Internet connection is back");
        self.connectionAvailable = YES;
    };
    internetReachability.unreachableBlock = ^(Reachability*reach)
    {
        WPLog(@"No internet connection");
        self.connectionAvailable = NO;
    };
    // start the notifier which will cause the reachability object to retain itself!
    [internetReachability startNotifier];
    
    // allocate the WP.com reachability object
    wpcomReachability = [Reachability reachabilityWithHostname:@"wordpress.com"];
    // set the blocks 
    wpcomReachability.reachableBlock = ^(Reachability*reach)
    {  
        WPLog(@"Connection to WordPress.com is back");
        self.wpcomAvailable = YES;
    };
    wpcomReachability.unreachableBlock = ^(Reachability*reach)
    {
        WPLog(@"No connection to WordPress.com");
        self.wpcomAvailable = NO;
    };
    // start the notifier which will cause the reachability object to retain itself!
    [wpcomReachability startNotifier];
    
    //Configure navigation bar style if >= iOS 5
    if([[UINavigationBar class] respondsToSelector:@selector(appearance)])
    {
        [[UINavigationBar appearance] setBackgroundImage:[UIImage imageNamed:@"navbar_bg"] forBarMetrics:UIBarMetricsDefault];
        [[UINavigationBar appearance] setTitleTextAttributes:
         [NSDictionary dictionaryWithObjectsAndKeys:
          [UIColor colorWithRed:70.0/255.0 green:70.0/255.0 blue:70.0/255.0 alpha:1.0], 
          UITextAttributeTextColor, 
          [UIColor colorWithRed:255.0/255.0 green:255.0/255.0 blue:255.0/255.0 alpha:1.0], 
          UITextAttributeTextShadowColor, 
          [NSValue valueWithUIOffset:UIOffsetMake(0, 1)], 
          UITextAttributeTextShadowOffset,
          nil]];
        [[UIBarButtonItem appearance] setTintColor:[UIColor colorWithRed:229.0/255.0 green:229.0/255.0 blue:229.0/255.0 alpha:1.0]];
        [[UIBarButtonItem appearance] setBackgroundImage:[UIImage imageNamed:@"navbar_button_bg"] forState: UIControlStateNormal barMetrics:UIBarMetricsDefault];
        [[UIBarButtonItem appearance] setBackgroundImage:[UIImage imageNamed:@"navbar_button_bg_active"] forState: UIControlStateSelected barMetrics:UIBarMetricsDefault];
        [[UIBarButtonItem appearance] setTitleTextAttributes:
         [NSDictionary dictionaryWithObjectsAndKeys:
          [UIColor colorWithRed:70.0/255.0 green:70.0/255.0 blue:70.0/255.0 alpha:1.0], 
          UITextAttributeTextColor, 
          [UIColor colorWithRed:255.0/255.0 green:255.0/255.0 blue:255.0/255.0 alpha:1.0], 
          UITextAttributeTextShadowColor,  
          [NSValue valueWithUIOffset:UIOffsetMake(0, 1)], 
          UITextAttributeTextShadowOffset,
          nil] forState:UIControlStateNormal];
        [[UIBarButtonItem appearance] setTitleTextAttributes:
         [NSDictionary dictionaryWithObjectsAndKeys:
          [UIColor colorWithRed:255.0/255.0 green:255.0/255.0 blue:255.0/255.0 alpha:1.0], 
          UITextAttributeTextColor, 
          [UIColor colorWithRed:70.0/255.0 green:70.0/255.0 blue:70.0/255.0 alpha:1.0], 
          UITextAttributeTextShadowColor,  
          [NSValue valueWithUIOffset:UIOffsetMake(0, 1)], 
          UITextAttributeTextShadowOffset,
          nil] forState:UIControlStateSelected];
    }
        	
	NSManagedObjectContext *context = [self managedObjectContext];
    if (!context) {
        NSLog(@"\nCould not create *context for self");
    }
	// Stats use core data, so run them after initialization
	[self checkIfStatsShouldRun];

	// Clean media files asynchronously
    // dispatch_async feels a bit faster than performSelectorOnBackground:
    // and we're trying to launch the app as fast as possible
    dispatch_async(dispatch_get_global_queue(0, 0), ^(void) {
        [self cleanUnusedMediaFileFromTmpDir];
    });

    [self checkWPcomAuthentication];

	crashReportView = [[CrashReportViewController alloc] initWithNibName:@"CrashReportView" bundle:nil];
	
	//BETA FEEDBACK BAR, COMMENT THIS OUT BEFORE RELEASE
	//BetaUIWindow *betaWindow = [[BetaUIWindow alloc] initWithFrame:CGRectZero];
	//betaWindow.hidden = NO;
	//BETA FEEDBACK BAR
    
    facebook = [[Facebook alloc] initWithAppId:kFacebookAppID andDelegate:self];
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kFacebookAccessTokenKey] 
        && [defaults objectForKey:kFacebookExpirationDateKey]) {
        facebook.accessToken = [defaults objectForKey:kFacebookAccessTokenKey];
        facebook.expirationDate = [defaults objectForKey:kFacebookExpirationDateKey];
    }
    
    SidebarViewController *sidebarViewController = [[[SidebarViewController alloc] init] autorelease];
    
    panelNavigationController = [[PanelNavigationController alloc] initWithDetailController:nil masterViewController:sidebarViewController];
    window.rootViewController = panelNavigationController;

	// Add listeners
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(deleteLocalDraft:)
												 name:@"LocalDraftWasPublishedSuccessfully" object:nil];
	
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(dismissCrashReporter:)
												 name:@"CrashReporterIsFinished" object:nil];
	
	
	//listener for XML-RPC errors
	//in the future we could put the errors message in a dedicated screen that users can bring to front when samething went wrong, and can take a look at the error msg.
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showNotificationErrorAlert:) name:kXML_RPC_ERROR_OCCURS object:nil];
	//TODO: we should add a screen? in which print the error msgs that are from async uploading errors --> PostUploadFailed
	
	// another notification message came from comments --> CommentUploadFailed
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showNotificationErrorAlert:) name:@"CommentUploadFailed" object:nil];

    // another notification message came from WPWebViewController
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showNotificationErrorAlert:) name:@"OpenWebPageFailed" object:nil];

    
	NSError *error;
	
	// Check if we previously crashed
	if ([crashReporter hasPendingCrashReport])
		[self handleCrashReport];
    
	// Enable the Crash Reporter
	if (![crashReporter enableCrashReporterAndReturnError: &error])
		NSLog(@"Warning: Could not enable crash reporter: %@", error);
	
	[window makeKeyAndVisible];

	[self registerForPushNotifications];
    
    //Information related to the reason for its launching, which can include things other than notifications.
    NSDictionary *remoteNotif = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
    if (remoteNotif) {
        NSLog(@"Launched with a remote notification as parameter:  %@", remoteNotif);
        [self openNotificationScreenWithOptions:remoteNotif];  
    }
    //the guide say: NO if the application cannot handle the URL resource, otherwise return YES. 
    //The return value is ignored if the application is launched as a result of a remote notification.

#if DEBUG
    /*
     A dictionary containing the credentials for all available protection spaces.
     The dictionary has keys corresponding to the NSURLProtectionSpace objects.
     The values for the NSURLProtectionSpace keys consist of dictionaries where the keys are user name strings, and the value is the corresponding NSURLCredential object.
     */
    [[[NSURLCredentialStorage sharedCredentialStorage] allCredentials] enumerateKeysAndObjectsUsingBlock:^(NSURLProtectionSpace *ps, NSDictionary *dict, BOOL *stop) {
        [dict enumerateKeysAndObjectsUsingBlock:^(id key, NSURLCredential *credential, BOOL *stop) {
            NSLog(@"Removing credential %@ for %@", [credential user], [ps host]);
            [[NSURLCredentialStorage sharedCredentialStorage] removeCredential:credential forProtectionSpace:ps];
        }];
    }];
#endif
    return YES;
}

-(BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url {
    if ([facebook handleOpenURL:url]){
        return YES;
    }

    if (url && [url isKindOfClass:[NSURL class]]) {
        NSString *URLString = [url absoluteString];
        NSLog(@"Application launched with URL: %@", URLString);
        if ([[url host] isEqualToString:@"oauth"]) {
            NSDictionary *params = [[url query] dictionaryFromQueryString];
            oauthCallback = [[params objectForKey:@"callback"] retain];
            NSString *clientId = [params objectForKey:@"client_id"];
            NSString *redirectUrl = [params objectForKey:@"redirect_uri"];
            NSString *secret = [params objectForKey:@"secret"];
            if (clientId && redirectUrl && secret && oauthCallback) {
                [WPComOAuthController presentWithClientId:clientId redirectUrl:redirectUrl clientSecret:secret delegate:self];
                return YES;
            }
        } else if ([[url absoluteString] hasPrefix:@"wordpress://wpcom_signup_completed"]) {
            NSDictionary *params = [[url query] dictionaryFromQueryString];
           // WPFLog(@"%@", params);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"wpcomSignupNotification" object:nil userInfo:params];
        }
        else if ([[CameraPlusPickerManager sharedManager] shouldHandleURLAsCameraPlusPickerCallback:url]) {
            /* Note that your application has been in the background and may have been terminated.
             * The only CameraPlusPickerManager state that is restored is the pickerMode, which is
             * restored to indicate the mode used to pick images.
             */
            
            /* Handle the callback and notify the delegate. */
            [[CameraPlusPickerManager sharedManager] handleCameraPlusPickerCallback:url usingBlock:^(CameraPlusPickedImages *images) {
                NSLog(@"Camera+ returned %@", [images images]);
                UIImage *image = [images image];
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
                NSDictionary *userInfo = [NSDictionary dictionaryWithObject:image forKey:@"image"];
                [[NSNotificationCenter defaultCenter] postNotificationName:kCameraPlusImagesNotification object:nil userInfo:userInfo];
            } cancelBlock:^(void) {
                NSLog(@"Camera+ picker canceled");
            }];
            return YES;
        }
    }
    return NO;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [FileLogger log:@"%@ %@", self, NSStringFromSelector(_cmd)];
    [self setAppBadge];
	
	if (DeviceIsPad()) {
//		UIViewController *topVC = self.masterNavigationController.topViewController;
//        
//		if (topVC && [topVC isKindOfClass:[BlogViewController class]]) {
//			[(BlogViewController *)topVC saveState];
//		}
	}
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [FileLogger log:@"%@ %@", self, NSStringFromSelector(_cmd)];
    
    //Keep the app alive in the background if we are uploading a post, currently only used for quick photo posts
    UIApplication *app = [UIApplication sharedApplication];
    if (!isUploadingPost && [app respondsToSelector:@selector(endBackgroundTask:)]) {
        if (bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    }
    
    if ([app respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)]) {
        bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
            // Synchronize the cleanup call on the main thread in case
            // the task actually finishes at around the same time.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (bgTask != UIBackgroundTaskInvalid)
                {
                    [app endBackgroundTask:bgTask];
                    bgTask = UIBackgroundTaskInvalid;
                }
            });
        }];
    }

    NSError *error = nil;
    if (![self.managedObjectContext save:&error]) {
        WPFLog(@"Unresolved Core Data Save error %@, %@", error, [error userInfo]);
        exit(-1);
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [FileLogger log:@"%@ %@", self, NSStringFromSelector(_cmd)];    
  
    if (passwordAlertRunning && passwordTextField != nil)
        [passwordTextField resignFirstResponder];
    else
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DismissAlertViewKeyboard" object:nil];
    
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [FileLogger log:@"%@ %@", self, NSStringFromSelector(_cmd)];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApplicationDidBecomeActive" object:nil];
    
    // Clear notifications badge and update server
    // TODO: read/unread management when there's an API for it
    [self setAppBadge];
    [self sendPushNotificationBlogsList];
}


- (void)application:(UIApplication *)application didChangeStatusBarFrame:(CGRect)oldStatusBarFrame {
	//The guide says: After calling this method, the application also posts a UIApplicationDidChangeStatusBarFrameNotification notification to give interested objects a chance to respond to the change.
	//but seems that the notification is never sent.
	//we are using a custom notification
	[[NSNotificationCenter defaultCenter] postNotificationName:DidChangeStatusBarFrame object:nil];
}


#pragma mark -
#pragma mark CrashReport Methods

- (void)handleCrashReport {
	PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
	NSData *crashData;
	NSError *error;
	
	// Try loading the crash report
	crashData = [crashReporter loadPendingCrashReportDataAndReturnError: &error];
	if (crashData == nil) {
		NSLog(@"Could not load crash report: %@", error);
		[crashReporter purgePendingCrashReport];
	}
	
	// We could send the report from here, but we'll just print out
	// some debugging info instead
	PLCrashReport *report = [[[PLCrashReport alloc] initWithData: crashData error: &error] autorelease];
	if (report == nil) {
		NSLog(@"Could not parse crash report");
		[crashReporter purgePendingCrashReport];
	}
	else {
		if([[NSUserDefaults standardUserDefaults] objectForKey:@"crash_report_dontbug"] == nil) {
			// Display CrashReportViewController
            UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:crashReportView];
            navController.modalPresentationStyle = UIModalPresentationFormSheet;
            [self.panelNavigationController presentModalViewController:navController animated:YES];
            [navController release];
		}
		else {
			[crashReporter purgePendingCrashReport];
		}
	}
	
	return;
}

- (void)dismissCrashReporter:(NSNotification *)notification {
    [self.panelNavigationController dismissModalViewControllerAnimated:YES];
}


#pragma mark -
#pragma mark Public Methods

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
	WPLog(@"Showing alert with title: %@", message);
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                          message:message
                          delegate:self
						cancelButtonTitle:NSLocalizedString(@"Need Help?", @"'Need help?' button label, links off to the WP for iOS FAQ.")
						otherButtonTitles:NSLocalizedString(@"OK", @"OK button label."), nil];
    [alert show];
    [alert release];
}

- (void)showNotificationErrorAlert:(NSNotification *)notification {
	NSString *cleanedErrorMsg = nil;
	
	if([self isAlertRunning] == YES) return; //another alert is already shown 
	[self setAlertRunning:YES];
	
	if([[notification object] isKindOfClass:[NSError class]]) {
		
		NSError *err  = (NSError *)[notification object];
		cleanedErrorMsg = [err localizedDescription];
		
		//org.wordpress.iphone --> XML-RPC errors
		if ([[err domain] isEqualToString:@"org.wordpress.iphone"]){
			if([err code] == 401)
				cleanedErrorMsg = NSLocalizedString(@"Sorry, you cannot access this feature. Please check your User Role on this blog.", @"");
			else if([err code] == 403) { //403 = bad username/password
				NSDictionary *errInfo = [notification userInfo];
				//check if the user has NOT changed the blog during the loading
				if( (errInfo != nil) && ([errInfo objectForKey:@"currentBlog"] != nil ) 
				   && currentBlog == [errInfo objectForKey:@"currentBlog"] ) {
                    passwordAlertRunning = YES;
					[self performSelectorOnMainThread:@selector(showPasswordAlert) withObject:nil waitUntilDone:NO];
				} else {
					//do not show the alert
					[self setAlertRunning:NO];
				}
				return;
			}
		}
        
        // ignore HTTP auth canceled errors
        if ([err.domain isEqual:NSURLErrorDomain] && err.code == NSURLErrorUserCancelledAuthentication) {
            [self setAlertRunning:NO];
            return;
        }
	} else { //the notification obj is a String
		cleanedErrorMsg  = (NSString *)[notification object];
	}
	
	if([cleanedErrorMsg rangeOfString:@"NSXMLParserErrorDomain"].location != NSNotFound )
		cleanedErrorMsg = NSLocalizedString(@"The app can't recognize the server response. Please, check the configuration of your blog.", @"");
	
	[self showAlertWithTitle:NSLocalizedString(@"Error", @"Generic popup title for any type of error.") message:cleanedErrorMsg];
}


- (void)showPasswordAlert {

	UILabel *labelPasswd;
	
	NSString *lineBreaks;
	
	if (DeviceIsPad())
		lineBreaks = @"\n\n\n\n";
	else 
		lineBreaks = @"\n\n\n";
	
	UIAlertView *customSizeAlert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Incorrect Password", @"If the password was lost, a popup asks the author to update their password, this is the popup's title.") 
															  message:lineBreaks // IMPORTANT
															 delegate:self 
													cancelButtonTitle:NSLocalizedString(@"Cancel", @"Cancel button label.") 
													otherButtonTitles:NSLocalizedString(@"Save", @"Save button label (saving content, ex: Post, Page, Comment)."), nil];
	
	customSizeAlert.tag = 101;
	
	labelPasswd = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 48.0, 260.0, 29.0)];
	labelPasswd.backgroundColor = [UIColor clearColor];
	labelPasswd.textColor = [UIColor whiteColor];
	labelPasswd.text = NSLocalizedString(@"Please update your password:", @"If the password was lost, a popup asks the author to update their password, this is the popup's description.");
	[customSizeAlert addSubview:labelPasswd];
	[labelPasswd release];
	
	passwordTextField = [[UITextField alloc]  initWithFrame:CGRectMake(12.0, 82.0, 260.0, 29.0)]; 
	[passwordTextField setBackgroundColor:[UIColor whiteColor]];
	[passwordTextField setContentVerticalAlignment: UIControlContentVerticalAlignmentCenter];
	passwordTextField.keyboardType = UIKeyboardTypeDefault;
	passwordTextField.secureTextEntry = YES;
	
	[passwordTextField setTag:123];
	
	[customSizeAlert addSubview:passwordTextField];
	
	//fix the dialog position for older devices on iOS 3
	float version = [[[UIDevice currentDevice] systemVersion] floatValue];
	if (version <= 3.1)
	{
		customSizeAlert.transform = CGAffineTransformTranslate(customSizeAlert.transform, 0.0, 100.0);
	}
	
	[customSizeAlert show];
	[customSizeAlert release];
	
	[passwordTextField becomeFirstResponder]; //this line should always be called on MainThread
    [passwordTextField release];
}

- (void)showContentDetailViewController:(UIViewController *)viewController {
    if (viewController) {
        [panelNavigationController pushViewController:viewController animated:YES];
    } else {
        [panelNavigationController popToRootViewControllerAnimated:YES];
    }
}


- (void)deleteLocalDraft:(NSNotification *)notification {
	NSString *uniqueID = [notification object];
	
	if(uniqueID != nil) {
		NSLog(@"deleting local draft: %@", uniqueID);
		NSEntityDescription *entity = [NSEntityDescription entityForName:@"Post" inManagedObjectContext:self.managedObjectContext];   
		NSFetchRequest *request = [[NSFetchRequest alloc] init];  
		[request setEntity:entity];   
		NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"dateModified" ascending:NO];  
		NSArray *sortDescriptors = [NSArray arrayWithObject:sortDescriptor];  
		[request setSortDescriptors:sortDescriptors];  
		[sortDescriptor release];
		NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(uniqueID == %@)", uniqueID];
		[request setPredicate:predicate];
		NSError *error;  
		NSMutableArray *postsToDelete = [[self.managedObjectContext executeFetchRequest:request error:&error] mutableCopy];   
		
		if (!postsToDelete) {  
			// Bad. Srsly.
		}
		
		for (NSManagedObject *post in postsToDelete) {
			[self.managedObjectContext deleteObject:post];
		}
		
		if (![self.managedObjectContext save:&error]) {
			WPFLog(@"Unresolved Core Data Save error %@, %@", error, [error userInfo]);
			exit(-1);
		}
		
		[postsToDelete release];
		[request release];
	}
}


#pragma mark -
#pragma mark Core Data stack

/**
 Returns the managed object context for the application.
 If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
 */
- (NSManagedObjectContext *)managedObjectContext {
    
    if (managedObjectContext_ != nil) {
        return managedObjectContext_;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        managedObjectContext_ = [[NSManagedObjectContext alloc] init];
        [managedObjectContext_ setPersistentStoreCoordinator:coordinator];
    }
    return managedObjectContext_;
}


/**
 Returns the managed object model for the application.
 If the model doesn't already exist, it is created from the application's model.
 */
- (NSManagedObjectModel *)managedObjectModel {
    
    if (managedObjectModel_ != nil) {
        return managedObjectModel_;
    }
    NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"WordPress" ofType:@"momd"];
    NSURL *modelURL = [NSURL fileURLWithPath:modelPath];
    managedObjectModel_ = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];    
    return managedObjectModel_;
}

/**
 Returns the persistent store coordinator for the application.
 If the coordinator doesn't already exist, it is created and the application's store added to it.
 */
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {
    
    if (persistentStoreCoordinator_ != nil) {
        return persistentStoreCoordinator_;
    }
    
    NSURL *storeURL = [NSURL fileURLWithPath: [[self applicationDocumentsDirectory] stringByAppendingPathComponent: @"WordPress.sqlite"]];
	
	// This is important for automatic version migration. Leave it here!
	NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
							 [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption,
							 [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption, nil];
	
	NSError *error = nil;
	
// The following conditional code is meant to test the detection of mapping model for migrations
// It should remain disabled unless you are debugging why migrations aren't run
#if FALSE
	WPFLog(@"Debugging migration detection");
	NSDictionary *sourceMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
																							  URL:storeURL
																							error:&error];
	if (sourceMetadata == nil) {
		WPFLog(@"Can't find source persistent store");
	} else {
		WPFLog(@"Source store: %@", sourceMetadata);
	}
	NSManagedObjectModel *destinationModel = [self managedObjectModel];
	BOOL pscCompatibile = [destinationModel
						   isConfiguration:nil
						   compatibleWithStoreMetadata:sourceMetadata];
	if (pscCompatibile) {
		WPFLog(@"No migration needed");
	} else {
		WPFLog(@"Migration needed");
	}
	NSManagedObjectModel *sourceModel = [NSManagedObjectModel mergedModelFromBundles:nil forStoreMetadata:sourceMetadata];
	if (sourceModel != nil) {
		WPFLog(@"source model found");
	} else {
		WPFLog(@"source model not found");
	}

	NSMigrationManager *manager = [[NSMigrationManager alloc] initWithSourceModel:sourceModel
																 destinationModel:destinationModel];
	//WPFLog(@"Bundle contents: %@", [[NSBundle mainBundle] pathsForResourcesOfType:@"cdm" inDirectory:nil]);
	NSMappingModel *mappingModel = [NSMappingModel mappingModelFromBundles:[NSArray arrayWithObject:[NSBundle mainBundle]]
															forSourceModel:sourceModel
														  destinationModel:destinationModel];
	if (mappingModel != nil) {
		WPFLog(@"mapping model found");
	} else {
		WPFLog(@"mapping model not found");
	}

	if (NO) {
		BOOL migrates = [manager migrateStoreFromURL:storeURL
												type:NSSQLiteStoreType
											 options:nil
									withMappingModel:mappingModel
									toDestinationURL:storeURL
									 destinationType:NSSQLiteStoreType
								  destinationOptions:nil
											   error:&error];

		if (migrates) {
			WPFLog(@"migration went OK");
		} else {
			WPFLog(@"migration failed: %@", [error localizedDescription]);
		}
	}
	
	WPFLog(@"End of debugging migration detection");
#endif
    persistentStoreCoordinator_ = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    if (![persistentStoreCoordinator_ addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error]) {
		WPFLog(@"Error opening the database. %@\nDeleting the file and trying again", error);
#ifdef DEBUGMODE 
		// Don't delete the database on debug builds
		// Makes migration debugging less of a pain
		abort();
#endif
		
		//delete the sqlite file and try again
		[[NSFileManager defaultManager] removeItemAtPath:storeURL.path error:nil];
		if (![persistentStoreCoordinator_ addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error]) {
			NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
			abort();
		}
		
		//if the app did not quit, show the alert to inform the users that the data have been deleted
		UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Error establishing database connection.", @"") 
														 message:NSLocalizedString(@"Please delete the app and reinstall.", @"") 
														delegate:nil 
											   cancelButtonTitle:NSLocalizedString(@"OK", @"") 
											   otherButtonTitles:nil] autorelease];
		[alert show];
    } else {
		// If there are no blogs and blogs.archive still exists, force import of blogs
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString *currentDirectoryPath = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wordpress"];
		NSString *blogsArchiveFilePath = [currentDirectoryPath stringByAppendingPathComponent:@"blogs.archive"];
		if ([fileManager fileExistsAtPath:blogsArchiveFilePath]) {
			NSManagedObjectContext *destMOC = [[NSManagedObjectContext alloc] init];
			[destMOC setPersistentStoreCoordinator:persistentStoreCoordinator_];

			MigrateBlogsFromFiles *blogMigrator = [[MigrateBlogsFromFiles alloc] init];
			[blogMigrator forceBlogsMigrationInContext:destMOC error:&error];
			[blogMigrator release];
			if (![destMOC save:&error]) {
				WPFLog(@"Error saving blogs-only migration: %@", error);
			}
			[destMOC release];
			[fileManager removeItemAtPath:blogsArchiveFilePath error:&error];
		}
	}
	[[FileLogger sharedInstance] flush];
    
    return persistentStoreCoordinator_;
}


#pragma mark -
#pragma mark Application's Documents directory

/**
 Returns the path to the application's Documents directory.
 */
- (NSString *)applicationDocumentsDirectory {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
}

- (NSString *)applicationUserAgent {
  return [[NSUserDefaults standardUserDefaults] objectForKey:@"UserAgent"];
}

#pragma mark -
#pragma mark Private Methods

- (void)setAppBadge {
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
}

- (void)checkWPcomAuthentication {
	NSString *authURL = @"https://wordpress.com/xmlrpc.php";
	
    NSError *error = nil;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"] != nil) {
        NSString *username = [[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"];
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"] != nil) {
            // Migrate password to keychain
            [SFHFKeychainUtils storeUsername:username
                                 andPassword:[[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"]
                              forServiceName:@"WordPress.com"
                              updateExisting:YES error:&error];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wpcom_password_preference"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        NSString *password = [SFHFKeychainUtils getPasswordForUsername:username
                                                        andServiceName:@"WordPress.com"
                                                                 error:&error];
        if (password != nil) {
            AFXMLRPCClient *client = [AFXMLRPCClient clientWithXMLRPCEndpoint:[NSURL URLWithString:authURL]];
            [client callMethod:@"wp.getUsersBlogs"
                    parameters:[NSArray arrayWithObjects:username, password, nil]
                       success:^(AFHTTPRequestOperation *operation, id responseObject) {
                           isWPcomAuthenticated = YES;
                           WPFLog(@"Logged in to WordPress.com as %@", username);
                       } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                           if ([error.domain isEqualToString:@"XMLRPC"] && error.code == 403) {
                               isWPcomAuthenticated = NO;
                           }
                           WPFLog(@"Error authenticating %@ with WordPress.com: %@", username, [error description]);
                       }];            
        } else {
            isWPcomAuthenticated = NO;
        }
	}
	else {
		isWPcomAuthenticated = NO;
	}
	
	if(isWPcomAuthenticated)
		[[NSUserDefaults standardUserDefaults] setObject:@"1" forKey:@"wpcom_authenticated_flag"];
	else
		[[NSUserDefaults standardUserDefaults] setObject:@"0" forKey:@"wpcom_authenticated_flag"];
}


- (void) checkIfStatsShouldRun {
    if (NO) { // Switch this to YES to debug stats/update check
        [self runStats];
        return;
    }
	//check if statsDate exists in user defaults, if not, add it and run stats since this is obviously the first time
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	//[defaults setObject:nil forKey:@"statsDate"];  // Uncomment this line to force stats.
	if (![defaults objectForKey:@"statsDate"]){
		NSDate *theDate = [NSDate date];
		[defaults setObject:theDate forKey:@"statsDate"];
		[self runStats];
	} else {
		//if statsDate existed, check if it's 7 days since last stats run, if it is > 7 days, run stats
		NSDate *statsDate = [defaults objectForKey:@"statsDate"];
		NSDate *today = [NSDate date];
		NSTimeInterval difference = [today timeIntervalSinceDate:statsDate];
		NSTimeInterval statsInterval = 7 * 24 * 60 * 60; //number of seconds in 30 days
		if (difference > statsInterval) //if it's been more than 7 days since last stats run
		{
            // WARNING: for some reason, if runStats is called in a background thread
            // NSURLConnection doesn't launch and stats are not sent
            // Don't change this or be really sure it's working
			[self runStats];
		}
	}
}

- (void)runStats {
	//generate and post the stats data
	/*
	 - device_uuid – A unique identifier to the iPhone/iPod that the app is installed on.
	 - app_version – the version number of the WP iPhone app
	 - language – language setting for the device. What does that look like? Is it EN or English?
	 - os_version – the version of the iPhone/iPod OS for the device
	 - num_blogs – number of blogs configured in the WP iPhone app
	 - device_model - kind of device on which the WP iPhone app is installed
	 */
	
	NSString *deviceModel = [[[UIDevice currentDevice] platform] stringByUrlEncoding];
	NSString *deviceuuid = [[UIDevice currentDevice] uniqueIdentifier];
	NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
	NSString *appversion = [[info objectForKey:@"CFBundleVersion"] stringByUrlEncoding];
	NSLocale *locale = [NSLocale currentLocale];
	NSString *language = [[locale objectForKey: NSLocaleIdentifier] stringByUrlEncoding];
	NSString *osversion = [[[UIDevice currentDevice] systemVersion] stringByUrlEncoding];
	int num_blogs = [Blog countWithContext:[self managedObjectContext]];
	NSString *numblogs = [[NSString stringWithFormat:@"%d", num_blogs] stringByUrlEncoding];
	
	//NSLog(@"UUID %@", deviceuuid);
	//NSLog(@"app version %@",appversion);
	//NSLog(@"language %@",language);
	//NSLog(@"os_version, %@", osversion);
	//NSLog(@"count of blogs %@",numblogs);
	//NSLog(@"device_model: %@", deviceModel);
	
	//handle data coming back
	// ** TODO @frsh: This needs to be completely redone with a custom helper class. ***
	[statsData release];
	statsData = [[NSMutableData alloc] init];
	
	NSMutableURLRequest *theRequest=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://api.wordpress.org/iphoneapp/update-check/1.0/"]
															cachePolicy:NSURLRequestUseProtocolCachePolicy
														timeoutInterval:30.0];
	
	[theRequest setHTTPMethod:@"POST"];
	[theRequest addValue:@"application/x-www-form-urlencoded" forHTTPHeaderField: @"Content-Type"];
	//create the body
	NSMutableData *postBody = [NSMutableData data];
	
	[postBody appendData:[[NSString stringWithFormat:@"device_uuid=%@&app_version=%@&language=%@&os_version=%@&num_blogs=%@&device_model=%@",
						   deviceuuid,
						   appversion,
						   language,
						   osversion,
						   numblogs,
						   deviceModel] dataUsingEncoding:NSUTF8StringEncoding]];
	
	//NSString *htmlStr = [[[NSString alloc] initWithData:postBody encoding:NSUTF8StringEncoding] autorelease];
	[theRequest setHTTPBody:postBody];
	
	NSURLConnection *conn = [[[NSURLConnection alloc] initWithRequest:theRequest delegate:self] autorelease];
	if(conn){
		// This is just to keep Analyzer from complaining.
	}

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSDate *theDate = [NSDate date];
	[defaults setObject:theDate forKey:@"statsDate"];
	[defaults synchronize];
}

- (void)cleanUnusedMediaFileFromTmpDir {
    [FileLogger log:@"%@ %@", self, NSStringFromSelector(_cmd)];
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	NSMutableArray *mediaToKeep = [NSMutableArray array];

    NSError *error = nil;
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
    [context setUndoManager:nil];
    [context setPersistentStoreCoordinator:self.persistentStoreCoordinator];
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:[NSEntityDescription entityForName:@"Media" inManagedObjectContext:context]];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"ANY posts.blog != NULL"];
    [fetchRequest setPredicate:predicate];
    NSArray *mediaObjectsToKeep = [context executeFetchRequest:fetchRequest error:&error];
    [context release];
    [fetchRequest release];
    if (error != nil) {
        WPFLog(@"Error cleaning up tmp files: %@", [error localizedDescription]);
    }
	//get a references to media files linked in a post
    NSLog(@"%i media items to check for cleanup", [mediaObjectsToKeep count]);
	for (Media *media in mediaObjectsToKeep) {
//        [mediaToKeep addObject:media.localURL];
	}

	//searches for jpg files within the app temp file
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsDirectory = [paths objectAtIndex:0];
	NSArray *contentsOfDir = [fileManager contentsOfDirectoryAtPath:documentsDirectory error:NULL];
    
    NSError *regexpError = NULL;
    NSRegularExpression *jpeg = [NSRegularExpression regularExpressionWithPattern:@".jpg$" options:NSRegularExpressionCaseInsensitive error:&regexpError];

	for (NSString *currentPath in contentsOfDir)
		if([jpeg numberOfMatchesInString:currentPath options:0 range:NSMakeRange(0, [currentPath length])] > 0) {
			NSString *filepath = [documentsDirectory stringByAppendingPathComponent:currentPath];

			BOOL keep = NO;
			//if the file is not referenced in any post we can delete it
			for (NSString *currentMediaToKeepPath in mediaToKeep) {
				if([currentMediaToKeepPath isEqualToString:filepath]) {
					keep = YES;
					break;
				}
			}

			if(keep == NO) {
				[fileManager removeItemAtPath:filepath error:NULL];
			}
		}

	[pool release];
}

#pragma mark - Push Notification delegate

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
	// Send the deviceToken to our server...
	NSString *myToken = [[[[deviceToken description]
					 stringByReplacingOccurrencesOfString: @"<" withString: @""]
					stringByReplacingOccurrencesOfString: @">" withString: @""]
				   stringByReplacingOccurrencesOfString: @" " withString: @""];
	
	// Store the token
	[[NSUserDefaults standardUserDefaults] setObject:myToken forKey:@"apnsDeviceToken"];
	NSLog(@"Registered for push notifications and stored device token: %@", 
		  [[NSUserDefaults standardUserDefaults] objectForKey:@"apnsDeviceToken"]);

    [self sendApnsToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
	NSLog(@"Failed to register for push notifications: %@", error);
}

// The notification is delivered when the application is running
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
    NSLog(@"didReceiveRemoteNotification: %@", userInfo);
    application.applicationIconBadgeNumber = 0;
    /*
     {
     aps =     {
     alert = "New comment on test from maria";
     badge = 1;
     sound = default;
     };
     "blog_id" = 16841252;
     "comment_id" = 571;
     }*/
    
    //You can determine whether an application is launched as a result of the user tapping the action button or 
    //whether the notification was delivered to the already-running application by examining the application state.
    switch (application.applicationState) {
        case UIApplicationStateActive:
            NSLog(@"app state UIApplicationStateActive"); //application is in foreground
            //we should show an alert since the OS doesn't show anything in this case. Unfortunately no sound!!
            if([self isAlertRunning] != YES) {
                id comment = [[userInfo objectForKey:@"aps"] objectForKey:@"alert"];
                NSString *message = nil;
                if ([comment isKindOfClass:[NSString class]]) {
                    message = (NSString *)comment;
                } else if ([comment isKindOfClass:[NSDictionary class]]) {
                    // Might be used in the future
                    WPLog(@"Received NSDictionary from Push Notification");
                }
                if (message && [message length] > 0) {
                    [self setAlertRunning:YES];
                    [lastNotificationInfo release];
                    lastNotificationInfo = [userInfo retain];
                    UIAlertView *alert = nil;
                    if ([userInfo objectForKey:@"blog_id"] && [userInfo objectForKey:@"comment_id"]) {
                        alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"New comment", @"Popup title for a new push notification (shown when you receive a push notification and the phone is not locked).")
                                                           message:message
                                                          delegate:self
                                                 cancelButtonTitle:NSLocalizedString(@"Dismiss", @"Popup dismiss button for a new push notification (shown when you receive a push notification and the phone is not locked).")
                                                 otherButtonTitles:NSLocalizedString(@"View", @"Popup view push notification button for a new push notification (shown when you receive a push notification and the phone is not locked)."), nil];
                    } else {
                        // Unsupported notification: show it but do nothing when it's dismissed
                        alert = [[UIAlertView alloc] initWithTitle:nil
                                                           message:message
                                                          delegate:self
                                                 cancelButtonTitle:NSLocalizedString(@"Dismiss", @"Popup dismiss button for a new push notification (shown when you receive a push notification and the phone is not locked).")
                                                 otherButtonTitles:nil];
                    }
                    alert.tag = kNotificationNewComment;
                    [alert show];
                    [alert release];
                    [self sendPushNotificationBlogsList];
                }
            }
            break;
        case UIApplicationStateInactive:
            NSLog(@"app state UIApplicationStateInactive"); //application is in bg and the user tapped the view button
             [self openNotificationScreenWithOptions:userInfo];
            break;
        case UIApplicationStateBackground:
            NSLog(@" app state UIApplicationStateBackground"); //?? doh!
            break;
        default:
            break;
    }
}

- (void)registerForPushNotifications {
    if (isWPcomAuthenticated) {
        [[UIApplication sharedApplication]
         registerForRemoteNotificationTypes:(UIRemoteNotificationTypeBadge |
                                             UIRemoteNotificationTypeSound |
                                             UIRemoteNotificationTypeAlert)];
    }
}

- (void)sendApnsToken {	
    NSString *token = [[NSUserDefaults standardUserDefaults] objectForKey:@"apnsDeviceToken"];
    if( nil == token ) return; //no apns token available
    
    NSString *authURL = kNotificationAuthURL;   	
    NSError *error = nil;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"] != nil) {
        NSString *username = [[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"];
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"] != nil) {
            // Migrate password to keychain
            [SFHFKeychainUtils storeUsername:username
                                 andPassword:[[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"]
                              forServiceName:@"WordPress.com"
                              updateExisting:YES error:&error];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wpcom_password_preference"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        NSString *password = [SFHFKeychainUtils getPasswordForUsername:username
                                                        andServiceName:@"WordPress.com"
                                                                 error:&error];
        if (password != nil) {
#ifdef DEBUG
            NSNumber *sandbox = [NSNumber numberWithBool:YES];
#else
            NSNumber *sandbox = [NSNumber numberWithBool:NO];
#endif
            AFXMLRPCClient *api = [[AFXMLRPCClient alloc] initWithXMLRPCEndpoint:[NSURL URLWithString:authURL]];
            [api callMethod:@"wpcom.mobile_push_register_token"
                 parameters:[NSArray arrayWithObjects:username, password, token, [[UIDevice currentDevice] uniqueIdentifier], @"apple", sandbox, nil]
                    success:^(AFHTTPRequestOperation *operation, id responseObject) {
                        WPFLog(@"Registered token %@, sending blogs list", token);
                        [self sendPushNotificationBlogsList];
                    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                        WPFLog(@"Couldn't register token: %@", [error localizedDescription]);
                    }];
            [api release];
        } 
	}
}

- (void)unregisterApnsToken {
    NSString *token = [[NSUserDefaults standardUserDefaults] objectForKey:@"apnsDeviceToken"];
    if( nil == token ) return; //no apns token available
    
    NSString *authURL = kNotificationAuthURL;   	
    NSError *error = nil;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"] != nil) {
        NSString *username = [[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"];
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"] != nil) {
            // Migrate password to keychain
            [SFHFKeychainUtils storeUsername:username
                                 andPassword:[[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"]
                              forServiceName:@"WordPress.com"
                              updateExisting:YES error:&error];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wpcom_password_preference"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        NSString *password = [SFHFKeychainUtils getPasswordForUsername:username
                                                        andServiceName:@"WordPress.com"
                                                                 error:&error];
        if (password != nil) {
#ifdef DEBUG
            NSNumber *sandbox = [NSNumber numberWithBool:YES];
#else
            NSNumber *sandbox = [NSNumber numberWithBool:NO];
#endif
            AFXMLRPCClient *api = [[AFXMLRPCClient alloc] initWithXMLRPCEndpoint:[NSURL URLWithString:authURL]];
            [api callMethod:@"wpcom.mobile_push_unregister_token"
                 parameters:[NSArray arrayWithObjects:username, password, token, [[UIDevice currentDevice] uniqueIdentifier], @"apple", sandbox, nil]
                    success:^(AFHTTPRequestOperation *operation, id responseObject) {
                        WPFLog(@"Unregistered token %@", token);
                    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                        WPFLog(@"Couldn't unregister token: %@", [error localizedDescription]);
                    }];
            [api release];
        } 
	}
}

- (void)sendPushNotificationBlogsList {    
    NSString *token = [[NSUserDefaults standardUserDefaults] objectForKey:@"apnsDeviceToken"];
    if( nil == token ) return; //no apns token available
    
    NSString *authURL = kNotificationAuthURL;   	
    NSError *error = nil;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"] == nil) return;
    NSString *username = [[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_username_preference"];
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"] != nil) {
        // Migrate password to keychain
        [SFHFKeychainUtils storeUsername:username
                             andPassword:[[NSUserDefaults standardUserDefaults] objectForKey:@"wpcom_password_preference"]
                          forServiceName:@"WordPress.com"
                          updateExisting:YES error:&error];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wpcom_password_preference"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    NSString *password = [SFHFKeychainUtils getPasswordForUsername:username
                                                    andServiceName:@"WordPress.com"
                                                             error:&error];
    if (password == nil) return;
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:[NSEntityDescription entityForName:@"Blog" inManagedObjectContext:self.managedObjectContext]];
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"blogName" ascending:YES];
    NSArray *sortDescriptors = [[NSArray alloc] initWithObjects:sortDescriptor, nil];
    [fetchRequest setSortDescriptors:sortDescriptors];
    NSArray *blogs = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
        
    NSMutableArray *blogsID = [NSMutableArray array];
    
    //get a references to media files linked in a post
    for (Blog *blog in blogs) {
        if( [blog isWPcom] ) {
            [blogsID addObject:[blog blogID] ];
        }
    }
    
    AFXMLRPCClient *api = [[AFXMLRPCClient alloc] initWithXMLRPCEndpoint:[NSURL URLWithString:authURL]];
    [api callMethod:@"wpcom.mobile_push_set_blogs_list"
         parameters:[NSArray arrayWithObjects:username, password, token, blogsID, nil]
            success:^(AFHTTPRequestOperation *operation, id responseObject) {
                WPFLog(@"Sent blogs list (%d blogs)", [blogsID count]);
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                WPFLog(@"Failed registering blogs list: %@", [error localizedDescription]);
            }];
    [api release];
    
    [fetchRequest release];
    [sortDescriptor release]; sortDescriptor = nil;
    [sortDescriptors release]; sortDescriptors = nil;
}

- (void)openNotificationScreenWithOptions:(NSDictionary *)remoteNotif {
    if ([remoteNotif objectForKey:@"blog_id"] && [remoteNotif objectForKey:@"comment_id"]) {
        WPFLog(@"Received notification: %@", remoteNotif);
        SidebarViewController *sidebar = (SidebarViewController *)self.panelNavigationController.masterViewController;
        [sidebar showCommentWithId:[remoteNotif objectForKey:@"comment_id"] blogId:[remoteNotif objectForKey:@"blog_id"]];
    } else {
        WPFLog(@"Got unsupported notification: %@", remoteNotif);
    }
}

#pragma mark -
#pragma mark NSURLConnection callbacks

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	[statsData appendData: data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError: (NSError *)error {
	UIAlertView *errorAlert = [[UIAlertView alloc]
							   initWithTitle: [error localizedDescription]
							   message: [error localizedFailureReason]
							   delegate:nil
							   cancelButtonTitle:NSLocalizedString(@"OK", @"OK button label (shown in popups).")
							   otherButtonTitles:nil];
	[errorAlert show];
	[errorAlert release];
}

- (void) connectionDidFinishLoading: (NSURLConnection*) connection {
	NSString *statsDataString = [[[NSString alloc] initWithData:statsData encoding:NSUTF8StringEncoding] autorelease];
    statsDataString = [[statsDataString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] objectAtIndex:0];
	NSString *appversion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
    if ([statsDataString compare:appversion options:NSNumericSearch] > 0) {
        NSLog(@"There's a new version: %@", statsDataString);
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Update Available", @"Popup title to highlight a new version of the app being available.")
                                                        message:NSLocalizedString(@"A new version of WordPress for iOS is now available", @"Generic popup message to highlight a new version of the app being available.")
                                                       delegate:self
                                              cancelButtonTitle:NSLocalizedString(@"Dismiss", @"Dismiss button label.")
                                              otherButtonTitles:NSLocalizedString(@"Update Now", @"Popup 'update' button to highlight a new version of the app being available. The button takes you to the app store on the device, and should be actionable."), nil];
        alert.tag = 102;
        [alert show];
        [alert release];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {

}

- (void) handleAuthenticationOKForChallenge:(NSURLAuthenticationChallenge *)aChallenge withUser:(NSString*)username password:(NSString*)password {

}

- (void) handleAuthenticationCancelForChallenge: (NSURLAuthenticationChallenge *)aChallenge {

}

#pragma mark -
#pragma mark UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex { 
	[self setAlertRunning:NO];
	
	if (alertView.tag == 101) { //Password Alert
        passwordAlertRunning = NO;
		if(currentBlog != nil) {
			NSError *error = nil;
			
			if ([passwordTextField.text isEqualToString:@""]) 
				return;
			
			//check if the current blog is a WP.COM blog
			if(currentBlog.isWPcom) {
				[SFHFKeychainUtils storeUsername:currentBlog.username
									 andPassword:passwordTextField.text
								  forServiceName:@"WordPress.com"
								  updateExisting:YES
										   error:&error];
			} else {
				[SFHFKeychainUtils storeUsername:currentBlog.username
									 andPassword:passwordTextField.text
								  forServiceName:currentBlog.hostURL
								  updateExisting:YES
										   error:&error];
			}
			
			if (error) {
				[FileLogger log:@"%@ %@ Error saving password for %@: %@", self, NSStringFromSelector(_cmd), currentBlog.url, error];
			} else {
				[FileLogger log:@"%@ %@ %@", self, NSStringFromSelector(_cmd), currentBlog.url];
			}
		}
    } else if (alertView.tag == 102) { // Update alert
        if (buttonIndex == 1) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"http://itunes.apple.com/us/app/wordpress/id335703880?mt=8&ls=1"]];
        }
    } else if (alertView.tag == kNotificationNewComment) {
        if (buttonIndex == 1) {
            [self openNotificationScreenWithOptions:lastNotificationInfo];
            [lastNotificationInfo release]; lastNotificationInfo = nil;
        }
	} else { 
		//Need Help Alert
		switch(buttonIndex) {
			case 0: {
				HelpViewController *helpViewController = [[HelpViewController alloc] init];
				WordPressAppDelegate *appDelegate = (WordPressAppDelegate *)[[UIApplication sharedApplication] delegate];
				
//				if (DeviceIsPad() && self.splitViewController.modalViewController) {
				if (DeviceIsPad() && self.panelNavigationController.modalViewController) {
					[self.navigationController pushViewController:helpViewController animated:YES];
				}
				else {
					if (DeviceIsPad()) {
						helpViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
						helpViewController.modalPresentationStyle = UIModalPresentationFormSheet;
//						[splitViewController presentModalViewController:helpViewController animated:YES];
					}
					else
						[appDelegate.navigationController presentModalViewController:helpViewController animated:YES];
				}
				
				[helpViewController release];
				break;
			}
			case 1:
				//ok
				break;
			default:
				break;
		}
		
	}
}

#pragma mark - WPComOAuthDelegate

- (void)controllerDidCancel:(WPComOAuthController *)controller {
    NSLog(@"OAuth canceled");
    NSURL *callback = [NSURL URLWithString:[NSString stringWithFormat:@"%@://wordpress-sso", oauthCallback]];
    [[UIApplication sharedApplication] openURL:callback];
}
- (void)controller:(WPComOAuthController *)controller didAuthenticateWithToken:(NSString *)token blog:(NSString *)blogUrl {
    NSLog(@"OAuth successful. Token %@ Blog %@", token, blogUrl);
    NSString *encodedToken = (NSString *)CFURLCreateStringByAddingPercentEscapes(
                                                                                 NULL,
                                                                                 (CFStringRef)token,
                                                                                 NULL,
                                                                                 (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                                                                 kCFStringEncodingUTF8 );
    NSURL *callback = [NSURL URLWithString:[NSString stringWithFormat:@"%@://wordpress-sso?token=%@&blog=%@",
                                            oauthCallback,
                                            encodedToken,
                                            [blogUrl stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
    [encodedToken release];
    NSLog(@"Launching %@", callback);
    [[UIApplication sharedApplication] openURL:callback];
}

#pragma mark - Facebook Delegate Methods

- (void)fbDidLogin {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[facebook accessToken] forKey:kFacebookAccessTokenKey];
    [defaults setObject:[facebook expirationDate] forKey:kFacebookExpirationDateKey];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:kFacebookLoginNotificationName object:self];
    
}

/**
 * Called when the user dismissed the dialog without logging in.
 */
- (void)fbDidNotLogin:(BOOL)cancelled
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kFacebookNoLoginNotificationName object:self];
}

/**
 * Called after the access token was extended. If your application has any
 * references to the previous access token (for example, if your application
 * stores the previous access token in persistent storage), your application
 * should overwrite the old access token with the new one in this method.
 * See extendAccessToken for more details.
 */
- (void)fbDidExtendToken:(NSString*)accessToken
               expiresAt:(NSDate*)expiresAt
{
    
}

/**
 * Called when the user logged out.
 */
- (void)fbDidLogout
{
}

/**
 * Called when the current session has expired. This might happen when:
 *  - the access token expired
 *  - the app has been disabled
 *  - the user revoked the app's permissions
 *  - the user changed his or her password
 */
- (void)fbSessionInvalidated
{
}


@end


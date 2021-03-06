//
//  iPhoneTrackingAppDelegate.m
//  iPhoneTracking
//
//  Created by Pete Warden on 4/15/11.
//

/***********************************************************************************
*
* All code (C) Pete Warden, 2011
*
*    This program is free software: you can redistribute it and/or modify
*    it under the terms of the GNU General Public License as published by
*    the Free Software Foundation, either version 3 of the License, or
*    (at your option) any later version.
*
*    This program is distributed in the hope that it will be useful,
*    but WITHOUT ANY WARRANTY; without even the implied warranty of
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*
*    GNU General Public License for more details.
*
*    You should have received a copy of the GNU General Public License
*    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*
************************************************************************************/

#import "iPhoneTrackingAppDelegate.h"
#import "fmdb/FMDatabase.h"
#import "parsembdb.h"

@implementation iPhoneTrackingAppDelegate

@synthesize window;
@synthesize webView;
@synthesize tableView;

- (id) init
{
  devicesArray = [[NSMutableArray alloc] init];
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
}

- displayErrorAndQuit:(NSString *)error
{
    [[NSAlert alertWithMessageText: @"Error"
      defaultButton:@"OK" alternateButton:nil otherButton:nil
      informativeTextWithFormat: error] runModal];
    exit(1);
}

- (void)awakeFromNib
{
  NSString* htmlString = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"]
      encoding:NSUTF8StringEncoding error:NULL];

 	[[webView mainFrame] loadHTMLString:htmlString baseURL:NULL];
  [webView setUIDelegate:self];
  [webView setFrameLoadDelegate:self]; 
  [webView setResourceLoadDelegate:self];

  // Set Datasource and Delegate of the TableView
  [tableView setDataSource: self];
  [tableView setDelegate: self];
}

- (void)debugLog:(NSString *) message
{
  NSLog(@"%@", message);
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)aSelector { return NO; }

- (void)webView:(WebView *)sender windowScriptObjectAvailable: (WebScriptObject *)windowScriptObject
{
  scriptObject = windowScriptObject;
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
  [self loadLocationDB];
}

- (void)loadLocationDB
{
  NSString* backupPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MobileSync/Backup/"];

  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray* backupContents = [[NSFileManager defaultManager] directoryContentsAtPath:backupPath];

  NSMutableArray* fileInfoList = [NSMutableArray array];
  for (NSString *childName in backupContents) {
    NSString* childPath = [backupPath stringByAppendingPathComponent:childName];

    NSString *plistFile = [childPath   stringByAppendingPathComponent:@"Info.plist"];
      
    NSError* error;
    NSDictionary *childInfo = [fm attributesOfItemAtPath:childPath error:&error];

    NSDate* modificationDate = [childInfo objectForKey:@"NSFileModificationDate"];    

    NSDictionary* fileInfo = [NSDictionary dictionaryWithObjectsAndKeys: 
      childPath, @"fileName",
      childName, @"childName",
      modificationDate, @"modificationDate", 
      plistFile, @"plistFile", 
      nil];
    [fileInfoList addObject: fileInfo];

  }
  
  NSSortDescriptor* sortDescriptor = [[[NSSortDescriptor alloc] initWithKey:@"modificationDate" ascending:NO] autorelease];
  [fileInfoList sortUsingDescriptors:[NSArray arrayWithObject:sortDescriptor]];
  
  BOOL loadWorked = NO;
  for (NSDictionary* fileInfo in fileInfoList) {
    @try {
      NSString* newestFolder = [fileInfo objectForKey:@"fileName"];
      NSString* plistFile = [fileInfo objectForKey:@"plistFile"];
      
      NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistFile];
      if (plist==nil) {
        NSLog(@"No plist file found at '%@'", plistFile);
        continue;
      }
      NSString* deviceName = [plist objectForKey:@"Device Name"];
      NSLog(@"file = %@, device = %@", plistFile, deviceName);  

      NSDictionary* mbdb = [ParseMBDB getFileListForPath: newestFolder];
      if (mbdb==nil) {
        NSLog(@"No MBDB file found at '%@'", newestFolder);
        continue;
      }

      NSString* wantedFileName = @"Library/Caches/locationd/consolidated.db";
      NSString* dbFileName = nil;
      for (NSNumber* offset in mbdb) {
        NSDictionary* fileInfo = [mbdb objectForKey:offset];
        NSString* fileName = [fileInfo objectForKey:@"filename"];
        if ([wantedFileName compare:fileName]==NSOrderedSame) {
          dbFileName = [fileInfo objectForKey:@"fileID"];
        }
      }

      if (dbFileName==nil) {
        NSLog(@"No consolidated.db file found in '%@'", newestFolder);
        continue;
      } else {
          NSLog(@"File found at '%@'", dbFileName);
      }

      NSString* dbFilePath = [newestFolder stringByAppendingPathComponent:dbFileName];

      // Add Device to Tableview
      NSDate * modificationDate = (NSDate *) [fileInfo objectForKey: @"modificationDate"];
      NSDateFormatter * dateFormater = [[NSDateFormatter alloc] init];
      [dateFormater setDateFormat:@"yyyy-MM-dd HH:mm"];
      NSString * modificationDateString = [dateFormater stringFromDate: modificationDate];
      
      NSDictionary * currentDeviceDictornary =
        [NSDictionary dictionaryWithObjectsAndKeys:
             modificationDateString, @"date"
            ,deviceName, @"device"
            ,dbFilePath, @"filename"
            ,nil
        ];
      
      [devicesArray addObject: currentDeviceDictornary];
      [currentDeviceDictornary retain];
      [modificationDate retain];
      [modificationDateString retain];
      [dateFormater retain];
      
      loadWorked = [self tryToLoadLocationDB: dbFilePath forDevice:deviceName];
    }
    @catch (NSException *exception) {
      NSLog(@"Exception: %@", [exception reason]);
    }
  }

  [tableView reloadData];
  
  if (!loadWorked) {
    [self displayErrorAndQuit: [NSString stringWithFormat: @"Couldn't load consolidated.db file from '%@'", backupPath]];  
  }
}

- (BOOL)tryToLoadLocationDB:(NSString*) locationDBPath forDevice:(NSString*) deviceName
{
  [scriptObject setValue:self forKey:@"cocoaApp"];
    
  FMDatabase* database = [FMDatabase databaseWithPath: locationDBPath];
  [database setLogsErrors: YES];
  BOOL openWorked = [database open];
  if (!openWorked) {
    return NO;
  }

  const float precision = 100;
  NSMutableDictionary* buckets = [NSMutableDictionary dictionary];

  NSString* queries[] = {
		@"SELECT * FROM CellLocation;", // GSM iPhone
		@"SELECT * FROM CdmaCellLocation;", // CDMA iPhone
	    @"SELECT * FROM WifiLocation;"};
	
  // Temporarily disabled WiFi location pulling, since it's so dodgy. Change to 
  for (int pass=0; pass<2; /*pass<3;*/ pass+=1) {
  
    FMResultSet* results = [database executeQuery:queries[pass]];

    while ([results next]) {
      NSDictionary* row = [results resultDict];

      NSNumber* latitude_number = [row objectForKey:@"latitude"];
      NSNumber* longitude_number = [row objectForKey:@"longitude"];
      NSNumber* timestamp_number = [row objectForKey:@"timestamp"];

      const float latitude = [latitude_number floatValue];
      const float longitude = [longitude_number floatValue];
      const float timestamp = [timestamp_number floatValue];
      
      // The timestamps seem to be based off 2001-01-01 strangely, so convert to the 
      // standard Unix form using this offset
      const float iOSToUnixOffset = (31*365.25*24*60*60);
      const float unixTimestamp = (timestamp+iOSToUnixOffset);
      
      if ((latitude==0.0)&&(longitude==0.0)) {
        continue;
      }
      
      const float weekInSeconds = (7*24*60*60);
      const float timeBucket = (floor(unixTimestamp/weekInSeconds)*weekInSeconds);
      
      NSDate* timeBucketDate = [NSDate dateWithTimeIntervalSince1970:timeBucket];

      NSString* timeBucketString = [timeBucketDate descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:nil locale:nil];

      const float latitude_index = (floor(latitude*precision)/precision);  
      const float longitude_index = (floor(longitude*precision)/precision);
      NSString* allKey = [NSString stringWithFormat:@"%f,%f,All Time", latitude_index, longitude_index];
      NSString* timeKey = [NSString stringWithFormat:@"%f,%f,%@", latitude_index, longitude_index, timeBucketString];

      [self incrementBuckets: buckets forKey: allKey];
      [self incrementBuckets: buckets forKey: timeKey];
    }
  }
  
  NSMutableArray* csvArray = [[[NSMutableArray alloc] init] autorelease];
  
  [csvArray addObject: @"lat,lon,value,time\n"];

  for (NSString* key in buckets) {
    NSNumber* count = [buckets objectForKey:key];

    NSArray* parts = [key componentsSeparatedByString:@","];
    NSString* latitude_string = [parts objectAtIndex:0];
    NSString* longitude_string = [parts objectAtIndex:1];
    NSString* time_string = [parts objectAtIndex:2];

    NSString* rowString = [NSString stringWithFormat:@"%@,%@,%@,%@\n", latitude_string, longitude_string, count, time_string];
    [csvArray addObject: rowString];
  }

  if ([csvArray count]<10) {
    return NO;
  }
  
  NSString* csvText = [csvArray componentsJoinedByString:@"\n"];
  
  id scriptResult = [scriptObject callWebScriptMethod: @"storeLocationData" withArguments:[NSArray arrayWithObjects:csvText,deviceName,nil]];
	if(![scriptResult isMemberOfClass:[WebUndefined class]]) {
		NSLog(@"scriptResult='%@'", scriptResult);
  }

  return YES;
}

- (void) incrementBuckets:(NSMutableDictionary*)buckets forKey:(NSString*)key
{
    NSNumber* existingValue = [buckets objectForKey:key];
    if (existingValue==nil) {
      existingValue = [NSNumber numberWithInteger:0];
    }
    NSNumber* newValue = [NSNumber numberWithInteger:([existingValue integerValue]+1)];

    [buckets setObject: newValue forKey: key];
}

- (IBAction)openAboutPanel:(id)sender {
    
    NSImage *img = [NSImage imageNamed: @"Icon"];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
               @"1.0", @"Version",
               @"iPhone Tracking", @"ApplicationName",
               img, @"ApplicationIcon",
               @"Copyright 2011, Pete Warden and Alasdair Allan", @"Copyright",
               @"iPhone Tracking v1.0", @"ApplicationVersion",
               nil];
    
    [[NSApplication sharedApplication] orderFrontStandardAboutPanelWithOptions:options];
    
}

#pragma Datasource for the NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
  return [devicesArray count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
  return [(NSDictionary *) [devicesArray objectAtIndex: rowIndex] objectForKey: [aTableColumn identifier]];
}

#pragma Delegate for the NSTableView

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex
{
  NSString * fileName = [(NSDictionary *) [devicesArray objectAtIndex: rowIndex] objectForKey: @"filename"];
  NSString * deviceName = [(NSDictionary *) [devicesArray objectAtIndex: rowIndex] objectForKey: @"device"];
  [self tryToLoadLocationDB: fileName forDevice: deviceName];
  return YES;
}

@end

//
//  UZKArchive.m
//  UnzipKit
//
//

#import "UZKArchive.h"

#import "zip.h"

#import "FileInZipInfo.h"
#import "ZipException.h"
#import "ZipFile.h"


NSString *UZKErrorDomain = @"UZKErrorDomain";
#define kMiniZipErrorDomain @"MiniZip error"

#define FILE_IN_ZIP_MAX_NAME_LENGTH (512)


@interface UZKArchive ()

@property (strong) NSData *fileBookmark;

@property (assign) ZipFileMode mode;
@property (assign) zipFile zipFile;
@property (assign) unzFile unzFile;
@property (strong) NSDictionary *archiveContents;

@end


@implementation UZKArchive



#pragma mark - Convenience Methods


+ (UZKArchive *)zipArchiveAtPath:(NSString *)filePath
{
    return [[UZKArchive alloc] initWithFile:[NSURL fileURLWithPath:filePath]];
}

+ (UZKArchive *)zipArchiveAtURL:(NSURL *)fileURL
{
    return [[UZKArchive alloc] initWithFile:fileURL];
}

+ (UZKArchive *)zipArchiveAtPath:(NSString *)filePath password:(NSString *)password
{
    return [[UZKArchive alloc] initWithFile:[NSURL fileURLWithPath:filePath]
                                   password:password];
}

+ (UZKArchive *)zipArchiveAtURL:(NSURL *)fileURL password:(NSString *)password
{
    return [[UZKArchive alloc] initWithFile:fileURL password:password];
}



#pragma mark - Initializers


- (id)initWithFile:(NSURL *)fileURL
{
    if ((self = [super init])) {
        NSError *error = nil;
        self.fileBookmark = [fileURL bookmarkDataWithOptions:0
                              includingResourceValuesForKeys:@[]
                                               relativeToURL:nil
                                                       error:&error];
        
        if (error) {
            NSLog(@"Error creating bookmark to ZIP archive: %@", error);
        }
    }
    
    return self;
}

- (id)initWithFile:(NSURL *)fileURL password:(NSString*)password
{
    if ((self = [self initWithFile:fileURL])) {
        self.password = password;
    }
    
    return self;
}



#pragma mark - Properties


- (NSURL *)fileURL
{
    BOOL bookmarkIsStale = NO;
    NSError *error = nil;
    
    NSURL *result = [NSURL URLByResolvingBookmarkData:self.fileBookmark
                                              options:0
                                        relativeToURL:nil
                                  bookmarkDataIsStale:&bookmarkIsStale
                                                error:&error];
    
    if (error) {
        NSLog(@"Error resolving bookmark to ZIP archive: %@", error);
        return nil;
    }
    
    if (bookmarkIsStale) {
        self.fileBookmark = [result bookmarkDataWithOptions:0
                             includingResourceValuesForKeys:@[]
                                              relativeToURL:nil
                                                      error:&error];
        
        if (error) {
            NSLog(@"Error creating fresh bookmark to ZIP archive: %@", error);
        }
    }
    
    return result;
}

- (NSString *)filename
{
    NSURL *url = self.fileURL;
    
    if (!url) {
        return nil;
    }
    
    return url.path;
}



#pragma mark - Public Methods


- (NSArray *)listFilenames:(NSError **)error
{
    NSError *unzipError;
    
    NSMutableArray *zipInfos = [NSMutableArray array];
    
    BOOL success = [self performActionWithArchiveOpen:^(NSError **innerError) {
        unzGoToNextFile(self.unzFile);
        
        unz_global_info gi;
        int err = unzGetGlobalInfo(self.unzFile, &gi);
        if (err != UNZ_OK) {
            [self assignError:error code:UZKErrorCodeArchiveNotFound];
            return;
        }
        
        NSUInteger fileCount = gi.number_entry;

        err = unzGoToFirstFile(_unzFile);
        
        if (err != UNZ_OK) {
            [self assignError:error code:UZKErrorCodeFileNavigationError];
            return;
        }

        for (NSInteger i = 0; i < fileCount; i++) {
            FileInZipInfo *info = [self currentFileInZipInfo:error];
            
            if (info) {
                [zipInfos addObject:info];
            } else {
                return;
            }

            err = unzGoToNextFile(self.unzFile);
            if (err == UNZ_END_OF_LIST_OF_FILE)
                return;
            
            if (err != UNZ_OK) {
                [self assignError:error code:UZKErrorCodeFileNavigationError];
                return;
            }
        }
    } inMode:ZipFileModeUnzip error:&unzipError];
    
    if (!success) {
        return nil;
    }
    
    return [zipInfos valueForKeyPath:@"name"];
}



#pragma mark - Private Methods


- (BOOL)performActionWithArchiveOpen:(void(^)(NSError **innerError))action
                              inMode:(ZipFileMode)mode
                               error:(NSError **)error
{
    if (error) {
        *error = nil;
    }
    
    if (![self openFile:self.filename
                 inMode:mode
           withPassword:self.password
                  error:error]) {
        return NO;
    }
    
    @try {
        action(error);
    }
    @finally {
        [self closeFile:error];
    }
    
    return !error || !*error;
}

- (BOOL)openFile:(NSString *)zipFile
          inMode:(ZipFileMode)mode
    withPassword:(NSString *)aPassword
           error:(NSError **)error
{
    if (error) {
        *error = nil;
    }
    
    switch (mode) {
        case ZipFileModeUnzip: {
            self.unzFile = unzOpen([self.filename cStringUsingEncoding:NSUTF8StringEncoding]);
            if (self.unzFile == NULL) {
                [self assignError:error code:UZKErrorCodeArchiveNotFound];
                return NO;
            }
            
            unzGoToFirstFile(_unzFile);
            
            NSMutableDictionary *dic = [NSMutableDictionary dictionary];
            
            do {
                FileInZipInfo *info = [self currentFileInZipInfo:error];
                
                if (!info) {
                    return NO;
                }
                
                unz_file_pos pos;
                int err = unzGetFilePos(_unzFile, &pos);
                if (err == UNZ_OK && info.name) {
                    [dic setObject:[NSArray arrayWithObjects:
                                    [NSNumber numberWithLong:pos.pos_in_zip_directory],
                                    [NSNumber numberWithLong:pos.num_of_file],
                                    nil] forKey:info.name];
                }
            } while (unzGoToNextFile (_unzFile) != UNZ_END_OF_LIST_OF_FILE);
            
            self.archiveContents = [NSDictionary dictionaryWithDictionary:dic];
            break;
        }
        case ZipFileModeCreate:
            self.zipFile = zipOpen([self.filename cStringUsingEncoding:NSUTF8StringEncoding], APPEND_STATUS_CREATE);
            if (self.zipFile == NULL) {
                [self assignError:error code:UZKErrorCodeArchiveNotFound];
                return NO;
            }
            break;

        case ZipFileModeAppend:
            self.zipFile = zipOpen([self.filename cStringUsingEncoding:NSUTF8StringEncoding], APPEND_STATUS_ADDINZIP);
            if (self.zipFile == NULL) {
                [self assignError:error code:UZKErrorCodeArchiveNotFound];
                return NO;
            }
            break;

        default:
            [NSException raise:@"Invalid UZKArchive openFile mode"
                        format:@"Unknown mode: %d for file: %@", mode, self.filename];
    }
    
    return YES;
}

- (void)closeFile:(NSError **)error
{
    int err;
    
    switch (self.mode) {
        case ZipFileModeUnzip:
            err = unzClose(_unzFile);
            if (err != UNZ_OK) {
                [self assignError:error code:UZKErrorCodeZLibError];
                return;
            }
            break;

        case ZipFileModeCreate:
            err = zipClose(_zipFile, NULL);
            if (err != ZIP_OK) {
                [self assignError:error code:UZKErrorCodeZLibError];
                return;
            }
            break;

        case ZipFileModeAppend:
            err= zipClose(_zipFile, NULL);
            if (err != ZIP_OK) {
                [self assignError:error code:UZKErrorCodeZLibError];
                return;
            }
            break;

        default:
            [NSException raise:@"Invalid UZKArchive closeFile mode"
                        format:@"Unknown mode: %d for file: %@", self.mode, self.filename];
    }
    
    self.mode = -1;
}

- (FileInZipInfo *)currentFileInZipInfo:(NSError **)error {
    if (self.mode != ZipFileModeUnzip) {
        [NSException raise:@"Invalid mode"
                    format:@"Must be in mode ZipFileModeUnzip, is in %d", self.mode];
    }
    
    char filename_inzip[FILE_IN_ZIP_MAX_NAME_LENGTH];
    unz_file_info file_info;
    
    int err = unzGetCurrentFileInfo(_unzFile, &file_info, filename_inzip, sizeof(filename_inzip), NULL, 0, NULL, 0);
    if (err != UNZ_OK) {
        [self assignError:error code:UZKErrorCodeArchiveNotFound];
        return nil;
    }
    
    NSString *name = [[NSString stringWithUTF8String:filename_inzip] decomposedStringWithCanonicalMapping];
    
    ZipCompressionLevel level = ZipCompressionLevelNone;
    if (file_info.compression_method != 0) {
        switch ((file_info.flag & 0x6) / 2) {
            case 0:
                level = ZipCompressionLevelDefault;
                break;
                
            case 1:
                level = ZipCompressionLevelBest;
                break;
                
            default:
                level = ZipCompressionLevelFastest;
                break;
        }
    }
    
    BOOL encrypted = ((file_info.flag & 1) != 0);
    
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.day    = file_info.tmu_date.tm_mday;
    components.month  = file_info.tmu_date.tm_mon + 1;
    components.year   = file_info.tmu_date.tm_year;
    components.hour   = file_info.tmu_date.tm_hour;
    components.minute = file_info.tmu_date.tm_min;
    components.second = file_info.tmu_date.tm_sec;
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *date = [calendar dateFromComponents:components];
    
    FileInZipInfo *info = [[FileInZipInfo alloc] initWithName:name
                                                       length:file_info.uncompressed_size
                                                        level:level
                                                      crypted:encrypted
                                                         size:file_info.compressed_size
                                                         date:date
                                                        crc32:file_info.crc];
    return info;
}

- (NSString *)errorNameForErrorCode:(UZKErrorCode)errorCode
{
    NSString *errorName;
    
    switch (errorCode) {
        case UZKErrorCodeZLibError:
            errorName = NSLocalizedString(@"Error reading/writing file", @"UZKErrorCodeZLibError");
            break;
            
        case UZKErrorCodeParameterError:
            errorName = NSLocalizedString(@"Parameter error", @"UZKErrorCodeParameterError");
            break;
            
        case UZKErrorCodeBadZipFile:
            errorName = NSLocalizedString(@"Bad zip file", @"UZKErrorCodeBadZipFile");
            break;
            
        case UZKErrorCodeInternalError:
            errorName = NSLocalizedString(@"Internal error", @"UZKErrorCodeInternalError");
            break;
            
        case UZKErrorCodeCRCError:
            errorName = NSLocalizedString(@"The data got corrupted during decompression",
                                          @"UZKErrorCodeCRCError");
            break;
            
        case UZKErrorCodeArchiveNotFound:
            errorName = NSLocalizedString(@"Can't open archive", @"UZKErrorCodeArchiveNotFound");
            break;
            
        default:
            errorName = [NSString stringWithFormat:@"Unknown error code: %ld", errorCode];
            break;
    }
    
    return errorName;
}

- (BOOL)assignError:(NSError **)error code:(NSInteger)errorCode
{
    if (error) {
        NSString *errorName = [self errorNameForErrorCode:errorCode];
        
        *error = [NSError errorWithDomain:UZKErrorDomain
                                     code:errorCode
                                 userInfo:@{NSLocalizedFailureReasonErrorKey: errorName}];
    }
    
    return NO;
}

- (void)handleZipException:(ZipException *)exception error:(NSError **)error
{
    if (error) {
        NSString *errorName = [self errorNameForErrorCode:exception.error];

        *error = [NSError errorWithDomain:kMiniZipErrorDomain
                                     code:exception.error
                                 userInfo:@{NSLocalizedFailureReasonErrorKey: errorName}];
    }
}


@end
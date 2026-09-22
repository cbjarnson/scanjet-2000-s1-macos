#import <Foundation/Foundation.h>

NSURL *SJQueueDirectory(void);
NSString *SJProcessingTool(void);
NSArray<NSDictionary *> *SJQueueJobs(void);
BOOL SJQueueAvailable(void);
void SJRetryFailedJobs(void);
NSURL *SJEnqueueScan(NSURL *job, NSURL *folder, NSArray<NSString *> *pages,
                     NSDictionary *settings, NSString *scanError, NSError **error);
int SJProcessJob(NSURL *manifest);
BOOL SJImageIsBlank(NSURL *url, NSError **error);

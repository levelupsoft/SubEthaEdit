//
//  TCMBEEPChannel.m
//  TCMBEEP
//
//  Created by Martin Ott on Wed Feb 18 2004.
//  Copyright (c) 2004 TheCodingMonkeys. All rights reserved.
//

#import "TCMBEEPChannel.h"
#import "TCMBEEPSession.h"
#import "TCMBEEPFrame.h"
#import "TCMBEEPMessage.h"
#import "TCMBEEPManagementProfile.h"

#import <netinet/tcp_seq.h> // sequence number comparison


static NSMutableDictionary *profileURIToClassMapping;


@interface TCMBEEPChannel (TCMBEEPChannelPrivateAdditions)

- (BOOL)TCM_validateFrame:(TCMBEEPFrame *)aFrame;

@end

#pragma mark -

@implementation TCMBEEPChannel

+ (void)initialize
{
    profileURIToClassMapping = [NSMutableDictionary new];
    [self setClass:[TCMBEEPManagementProfile class] forProfileURI:kTCMBEEPManagementProfile];
}

+ (NSDictionary *)profileURIToClassMapping
{
    return profileURIToClassMapping;
}

+ (void)setClass:(Class)aClass forProfileURI:(NSString *)aProfileURI
{
    [profileURIToClassMapping setObject:aClass forKey:aProfileURI];
}

- (id)initWithSession:(TCMBEEPSession *)aSession number:(unsigned long)aNumber profileURI:(NSString *)aProfileURI asInitiator:(BOOL)isInitiator
{
    self = [super init];
    if (self) {
        Class profileClass = nil;
        if ((profileClass = [[TCMBEEPChannel profileURIToClassMapping] objectForKey:aProfileURI])) {
            I_profile = [[profileClass alloc] initWithChannel:self];
            [I_profile setProfileURI:aProfileURI];
            [self setSession:aSession];
            [self setNumber:aNumber];
            [self setProfileURI:aProfileURI];
            I_previousReadFrame = nil;
            I_currentReadMessage = nil;
            I_messageNumbersWithPendingReplies = [NSMutableIndexSet new];
            I_unacknowledgedMessageNumbers = [NSMutableIndexSet new];
            I_inboundMessageNumbersWithPendingReplies = [NSMutableIndexSet new];
            I_defaultReadQueue = [NSMutableArray new];
            I_answerReadQueues = [NSMutableDictionary new];
            I_nextMessageNumber = 0;
            I_messageWriteQueue = [NSMutableArray new];
            I_outgoingFrameQueue = [NSMutableArray new];
            I_sequenceNumber = 0;
            I_incomingWindowSize = 4096;
            I_incomingBufferSize = 4096;
            I_incomingBufferSizeAvailable = 4096;
            I_incomingSequenceNumber = 0;
            I_outgoingWindowSize = 4096;
            I_flags.isInitiator = isInitiator;
            I_channelStatus = TCMBEEPChannelStatusOpen;
        }
    }
    
    return self;
}

- (void)dealloc
{
    I_session = nil;
    [I_profileURI release];
    [I_profile release];
    [I_previousReadFrame release];
    [I_currentReadMessage release];
    [I_messageNumbersWithPendingReplies release];
    [I_unacknowledgedMessageNumbers release];
    [I_inboundMessageNumbersWithPendingReplies release];
    [I_defaultReadQueue release];
    [I_answerReadQueues release];
    [I_messageWriteQueue release];
    [I_outgoingFrameQueue release];
    DEBUGLOG(@"BEEPLogDomain", SimpleLogLevel, @"Channel deallocated");
    [super dealloc];
}

- (BOOL)isInitiator
{
    return I_flags.isInitiator;
}

- (void)setPreviousReadFrame:(TCMBEEPFrame *)aFrame
{
    [I_previousReadFrame autorelease];
    I_previousReadFrame = [aFrame retain];
}

- (TCMBEEPFrame *)previousReadFrame
{
    return I_previousReadFrame;
}

- (void)setCurrentReadMessage:(TCMBEEPMessage *)aMessage
{
    [I_currentReadMessage autorelease];
    I_currentReadMessage = [aMessage retain];
}

- (TCMBEEPMessage *)currentReadMessage
{
    return I_currentReadMessage;
}


- (void)setNumber:(unsigned long)aNumber
{
    I_number = aNumber;
}

- (unsigned long)number
{
    return I_number;
}

- (void)setSession:(TCMBEEPSession *)aSession
{
    I_session = aSession;
}

- (TCMBEEPSession *)session
{
    return I_session;
}

- (void)setProfileURI:(NSString *)aProfileURI
{
    [I_profileURI autorelease];
    I_profileURI = [aProfileURI copy];
}

- (NSString *)profileURI
{
    return I_profileURI;
}

- (id)profile
{
    return I_profile;
}

- (TCMBEEPChannelStatus)channelStatus
{
    return I_channelStatus;
}

// standard conform close
- (void)close
{
    I_channelStatus = TCMBEEPChannelStatusAtEnd;
    
    // comply with requirements before sending close frame
    BOOL isMSGInQueue = NO;
    NSEnumerator *messages = [I_messageWriteQueue objectEnumerator];
    TCMBEEPMessage *message;
    while ((message == [messages nextObject])) {
        if ([message isMSG]) {
            isMSGInQueue = YES;
            break;
        }
    }
    
    if (!isMSGInQueue && [I_unacknowledgedMessageNumbers count] == 0) {
        [[self session] closeChannelWithNumber:[self number] code:200];
        I_channelStatus = TCMBEEPChannelStatusClosing;
    }
}

// Convenience for Profiles
- (void)sendMSGMessageWithPayload:(NSData *)aPayload
{
    if (I_channelStatus == TCMBEEPChannelStatusAtEnd ||
        I_channelStatus == TCMBEEPChannelStatusClosing ||
        I_channelStatus == TCMBEEPChannelStatusCloseRequested) {
        NSLog(@"Trying to send message after telling channel to close");
        return;
    }
    [self sendMessage:[[[TCMBEEPMessage alloc] initWithTypeString:@"MSG" messageNumber:[self nextMessageNumber] payload:aPayload] autorelease]];
}

// Accessors for session
- (BOOL)hasFramesAvailable
{
    //DEBUGLOG(@"BEEPLogDomain", AllLogLevel, @"frames available? %d", ([I_messageWriteQueue count] > 0));
    return ([I_messageWriteQueue count] > 0 || [I_outgoingFrameQueue count] > 0);
}

- (NSArray *)availableFramesFittingInCurrentWindow;
{
    if ([I_messageWriteQueue count] == 0 && [I_outgoingFrameQueue count] == 0) {
        return [NSArray array];
    }
    
    NSMutableArray *frames = [NSMutableArray array];
    [frames addObjectsFromArray:I_outgoingFrameQueue];
    [I_outgoingFrameQueue removeAllObjects];
    
    int bytesAllowedToSend = MIN([[self session] maximumFrameSize], I_outgoingWindowSize);
    while (bytesAllowedToSend > 0 && [I_messageWriteQueue count] > 0) {
        TCMBEEPMessage *message = [I_messageWriteQueue objectAtIndex:0];
        int payloadLength = [message payloadLength];
        if (payloadLength <= bytesAllowedToSend) {
            // convert message to frame and send frame
            TCMBEEPFrame *frame = [TCMBEEPFrame frameWithMessage:message sequenceNumber:I_sequenceNumber payloadLength:payloadLength intermediate:NO];
            I_outgoingWindowSize -= payloadLength;
            [frames addObject:frame];
            [I_messageWriteQueue removeObjectAtIndex:0];
            I_sequenceNumber += payloadLength;
            bytesAllowedToSend -= payloadLength;
        } else {
            // split message into several frames
            int framePayload = bytesAllowedToSend;
            TCMBEEPFrame *frame = [TCMBEEPFrame frameWithMessage:message sequenceNumber:I_sequenceNumber payloadLength:framePayload intermediate:YES];
            [message setPayload:[[message payload] subdataWithRange:NSMakeRange(framePayload, payloadLength - framePayload)]];
            [frames addObject:frame];
            I_outgoingWindowSize -= framePayload;
            I_sequenceNumber += framePayload;
            bytesAllowedToSend -= framePayload;
        }
    }
    
    if (I_channelStatus == TCMBEEPChannelStatusCloseRequested) {
        if ([I_messageWriteQueue count] == 0 && 
            [I_messageNumbersWithPendingReplies count] == 0 && 
            [I_inboundMessageNumbersWithPendingReplies count] == 0) {
            [[self session] acceptCloseRequestForChannelWithNumber:[self number]];
        }
    }
    
    return frames;
}

- (int32_t)nextMessageNumber
{
    if (I_nextMessageNumber < 0) I_nextMessageNumber = 0;
    return I_nextMessageNumber++;
}

- (BOOL)acceptFrame:(TCMBEEPFrame *)aFrame
{
    if ([aFrame isSEQ]) {
        // validate SEQ frame;
        uint32_t ackno = [aFrame sequenceNumber];
        //if (ackno > I_sequenceNumber) {
        if (SEQ_GT(ackno, I_sequenceNumber)) {
            NSLog(@"ERROR! More bytes received by peer than sent to him.");
            return NO;
        }
        int32_t window = [aFrame length];
        I_outgoingWindowSize += window;
        return YES;
    }
    
    BOOL accept = [self TCM_validateFrame:aFrame];
    if (accept) {
        // QUEUE   
        NSMutableArray *queue = nil; 
        if ([aFrame isANS]) {
            NSArray *queue = [I_answerReadQueues objectForLong:[aFrame answerNumber]];
            if (!queue) {
                queue = [NSMutableArray array];
                [I_answerReadQueues setObject:queue forLong:[aFrame answerNumber]];
            }
        } else {
            queue = I_defaultReadQueue;
        }
        [queue addObject:aFrame];
    
        if (![aFrame isIntermediate]) {
            // FINISH and DISPATCH
            TCMBEEPMessage *message = [TCMBEEPMessage messageWithQueue:queue];
            if ([aFrame isMSG]) {
                [I_inboundMessageNumbersWithPendingReplies addIndex:[aFrame messageNumber]];
            } else if (![aFrame isANS]) {
                [I_messageNumbersWithPendingReplies removeIndex:[aFrame messageNumber]];
            }
            [[self profile] processBEEPMessage:message];
            if ([aFrame isANS]) {
                [I_answerReadQueues removeObjectForLong:[aFrame answerNumber]];
            } else {
                [queue removeAllObjects];
            }
            if ([aFrame isNUL]) {
                // FEHLER?
                if ([I_answerReadQueues count] > 0) {
                    // FEHLER! bei NUL m�ssen alle Antworten abgeschlossen sein...
                }
            }
        }
        

        if (![aFrame isMSG]) {
            [I_unacknowledgedMessageNumbers removeIndex:[aFrame messageNumber]];
            if ([I_unacknowledgedMessageNumbers count] == 0) {
                if  (I_channelStatus == TCMBEEPChannelStatusAtEnd) {
                    I_channelStatus = TCMBEEPChannelStatusClosing;
                    [[self session] closeChannelWithNumber:[self number] code:200];
                }
            }
        }
        
        if (I_channelStatus == TCMBEEPChannelStatusCloseRequested) {
            if ([I_messageWriteQueue count] == 0 && 
                [I_messageNumbersWithPendingReplies count] == 0 && 
                [I_inboundMessageNumbersWithPendingReplies count] == 0) {
                [[self session] acceptCloseRequestForChannelWithNumber:[self number]];
            }
        }
            
        [self setPreviousReadFrame:aFrame];
        I_incomingSequenceNumber = [aFrame sequenceNumber];
        I_incomingBufferSizeAvailable -= [aFrame length];
        if (I_incomingBufferSizeAvailable < 2048) {
            // prepare SEQ frame
            TCMBEEPFrame *SEQFrame = [TCMBEEPFrame SEQFrameWithChannelNumber:[self number] acknowledgementNumber:I_incomingSequenceNumber windowSize:4096];
            I_incomingBufferSizeAvailable = I_incomingBufferSize;
            [I_outgoingFrameQueue addObject:SEQFrame];
            [[self session] channelHasFramesAvailable:self];
        }
    } else {
        NSLog(@"NOT ACCEPTED: %@", aFrame);
    }
    return accept;
}

#pragma mark -

- (BOOL)TCM_validateFrame:(TCMBEEPFrame *)aFrame
{
    char *messageType = [aFrame messageType];
    TCMBEEPFrame *previousReadFrame = [self previousReadFrame];
    
    BOOL result = YES;
    
    //  Checking for poorly-formed frames as stated in section 2.2.1.1 RFC3080.

    //  if the header doesn't start with "MSG", "RPY", "ERR", "ANS", or
    //  "NUL";
    if (!(strcmp(messageType, "MSG") == 0 ||
          strcmp(messageType, "RPY") == 0 ||
          strcmp(messageType, "ERR") == 0 ||
          strcmp(messageType, "ANS") == 0 ||
          strcmp(messageType, "NUL") == 0)) {
        NSLog(@"1ter punkt 2.2.1.1");
        result = NO;
    }
                
    //  if the header starts with "MSG", and the message number refers to
    //  a "MSG" message that has been completely received but for which a
    //  reply has not been completely sent;
    if (strcmp(messageType, "MSG") == 0 &&
        [I_inboundMessageNumbersWithPendingReplies containsIndex:[aFrame messageNumber]]) {
        NSLog(@"4ter punkt 2.2.1.1");
        result = NO;
    }
    
    //  if the header doesn't start with "MSG", and refers to a message
    //  number for which a reply has already been completely received;
    if ((strcmp(messageType, "MSG") != 0)) {
        if (![I_messageNumbersWithPendingReplies containsIndex:[aFrame messageNumber]]
            && !([aFrame channelNumber] == 0 && strcmp(messageType, "RPY") == 0 &&
                 [aFrame messageNumber] == 0)) {
            NSLog(@"5ter punkt 2.2.1.1");
            result = NO;
        }
        
    }
    
    //  if the header starts with "NUL", and refers to a message number
    //  for which at least one other frame has been received, and the
    //  keyword of of the immediately-previous received frame for this
    //  reply isn't "ANS";
    if (strcmp(messageType, "NUL") == 0) {
        if ([self previousReadFrame] && !(strcmp([[self previousReadFrame] messageType], "ANS") == 0)) {
            NSLog(@"8ter punkt 2.2.1.1");
            result = NO;
        }
    }

    //  if the continuation indicator of the previous frame received on
    //  the same channel was intermediate ("*"), and its message number
    //  isn't identical to this frame's message number;
    if (previousReadFrame && [previousReadFrame isIntermediate]) {
        if ([aFrame messageNumber] != [previousReadFrame messageNumber])  {
            NSLog(@"9ter punkt 2.2.1.1");
            result = NO;
        }
    }

    //  if the value of the sequence number doesn't correspond to the
    //  expected value for the associated channel (c.f., Section 2.2.1.2);
    //  or,
    if (previousReadFrame) {
        if ([previousReadFrame isIntermediate] ||
            (strcmp([previousReadFrame messageType], "ANS") == 0 &&
             strcmp(messageType, "ANS") == 0)) {
            //if ([aFrame sequenceNumber] != 
            //    ([previousReadFrame sequenceNumber] + [previousReadFrame length])) {
            if (!SEQ_LEQ([aFrame sequenceNumber], ([previousReadFrame sequenceNumber] + [previousReadFrame length]))) {
                NSLog(@"10ter punkt 2.2.1.1 (Check sequence numbers)");
                result = NO;
            }
        }
    }
                
    //  if the header starts with "NUL", and the continuation indicator is
    //  intermediate ("*") or the payload size is non-zero.
    if (strcmp(messageType, "NUL") == 0 && [aFrame isIntermediate]) {
        NSLog(@"11ter punkt 2.2.1.1");
        result = NO;
    }
    
    return result;
}

- (void)sendMessage:(TCMBEEPMessage *)aMessage
{
    // validate message, return NSError
    // ...
    [aMessage setChannelNumber:[self number]];
    if ([[aMessage messageTypeString] isEqualTo:@"MSG"]) {
        if (I_channelStatus == TCMBEEPChannelStatusAtEnd || 
            I_channelStatus == TCMBEEPChannelStatusClosing ||
            I_channelStatus == TCMBEEPChannelStatusCloseRequested) {
            NSLog(@"Trying to send message after telling channel to close");
            return;
        }
        [I_messageNumbersWithPendingReplies addIndex:[aMessage messageNumber]];
        [I_unacknowledgedMessageNumbers addIndex:[aMessage messageNumber]];
    } else if (![[aMessage messageTypeString] isEqualTo:@"ANS"]) {
        [I_inboundMessageNumbersWithPendingReplies removeIndex:[aMessage messageNumber]];
    }
    [I_messageWriteQueue addObject:aMessage];
    DEBUGLOG(@"BEEPLogDomain", AllLogLevel, @"sendMessageQueue = %@", I_messageWriteQueue);
    [[self session] channelHasFramesAvailable:self];
}

- (void)cleanup
{
    [[self profile] cleanup];
    [[self profile] setChannel:nil];
    [I_profile release];
    I_profile = nil;
}

- (void)closed
{
    I_channelStatus = TCMBEEPChannelStatusClosed;
    [[self profile] channelDidClose];
}

- (void)closeFailedWithError:(NSError *)error
{
    // status?
    [[self profile] channelDidNotCloseWithError:error];
}

- (void)closeRequested
{
    DEBUGLOG(@"BEEPLogDomain", SimpleLogLevel, @"closeRequested");
    I_channelStatus = TCMBEEPChannelStatusCloseRequested;
    [[self profile] channelDidReceiveCloseRequest];
    if ([I_messageWriteQueue count] == 0 && 
        [I_messageNumbersWithPendingReplies count] == 0 && 
        [I_inboundMessageNumbersWithPendingReplies count] == 0) {
        [[self session] acceptCloseRequestForChannelWithNumber:[self number]];
    }
}

@end


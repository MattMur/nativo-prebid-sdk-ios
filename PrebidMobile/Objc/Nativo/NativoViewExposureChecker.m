/*   Copyright 2018-2021 Prebid.org, Inc.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "NativoViewExposureChecker.h"

#ifdef DEBUG
    #import "Prebid+TestExtension.h"
#endif
#import "SwiftImport.h"

@interface NativoViewExposureChecker()

@property (nonatomic, nullable, weak, readonly) UIView *testedView;
@property (nonatomic, assign, readwrite) CGRect clippedRect;
@property (nonatomic, nonnull, strong, readonly) NSMutableArray<NSValue *> *obstructions; // [CGRect]

@end

@implementation NativoViewExposureChecker

- (instancetype)initWithView:(UIView *)view {
    if (!(self = [super initWithView:view])) {
        return nil;
    }
    _testedView = view;
    _obstructions = [[NSMutableArray alloc] init];
    return self;
}

- (id<PBMViewExposure>)exposure {
    self.clippedRect = self.testedView.bounds;
    [self.obstructions removeAllObjects];
        
#   ifdef DEBUG
    if (Prebid.shared.forcedIsViewable) {
        return [PBMFactory createViewExposureWithExposureFactor:1 visibleRectangle:self.testedView.bounds occlusionRectangles:nil];
    }
#   endif
    
    if (!self.testedView || self.testedView.isHidden || self.testedView.superview == nil || ![self isOnForeground]) {
        return [PBMFactory.ViewExposureType zeroExposure];
    }
    
    BOOL potentiallyExposed = [self visitParent:self.testedView.superview fromChild:self.testedView] && [self collapseBoundingBox];
    if (!potentiallyExposed) {
        return [PBMFactory.ViewExposureType zeroExposure];
    }
    
    NSArray<NSValue *> * const obstructions = [self buildObstructionRects];
    CGSize const fullSize = self.testedView.bounds.size;
    float const fullArea = fullSize.width * fullSize.height;
    float const clipArea = self.clippedRect.size.width * self.clippedRect.size.height;
    float obstructedArea = 0;
    for(NSValue *rect in obstructions) {
        CGSize const nextSize = rect.CGRectValue.size;
        obstructedArea += nextSize.width * nextSize.height;
    }
    
    return [PBMFactory createViewExposureWithExposureFactor:(clipArea - obstructedArea)/fullArea
                                           visibleRectangle:self.clippedRect
                                        occlusionRectangles:obstructions];
}

// MARK: - Private API

- (BOOL)isOnForeground {
    UIWindow * const window = self.testedView.window;
    if (!window) {
        return NO;
    }
    
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return NO;
    }
    
    if (@available(iOS 13.0, *)) {
        return (window.windowScene != nil && window.windowScene.activationState == UISceneActivationStateForegroundActive);
    } else {
        return YES;
    }
}

// Use a small epsilon to treat nearly-transparent as transparent
static const CGFloat kAlphaEpsilon = 0.01;

// Cache WKWebView class lookup once
+ (Class)wkWebViewClass {
    static Class wkClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        wkClass = NSClassFromString(@"WKWebView");
    });
    return wkClass;
}

- (BOOL)isEffectivelyHidden:(UIView *)view {
    if (!view || view.isHidden) {
        return YES;
    }
    if (view.alpha <= kAlphaEpsilon) {
        return YES;
    }
    if (CGRectIsEmpty(view.bounds)) {
        return YES;
    }
    if (self.testedView.window == nil || view.window == nil) {
        return YES;
    }
    return NO;
}

// Extract alpha from UIColor or return 0 if nil
- (CGFloat)alphaForUIColor:(UIColor *)color {
    if (!color) { return 0.0; }
    CGFloat a = 0;
    if ([color respondsToSelector:@selector(getRed:green:blue:alpha:)]) {
        CGFloat r, g, b;
        if ([color getRed:&r green:&g blue:&b alpha:&a]) {
            return a;
        }
    }
    CGColorRef cg = color.CGColor;
    if (cg) {
        return CGColorGetAlpha(cg);
    }
    return 1.0;
}

// Heuristically determine whether the view draws non-transparent content in its bounds
- (BOOL)viewHasOpaqueVisualContent:(UIView *)view {
    // Combine view.alpha and layer.opacity
    if (view.alpha <= kAlphaEpsilon) {
        return NO;
    }
    if (view.layer.opacity <= kAlphaEpsilon) {
        return NO;
    }
    
    // Backgrounds
    CGFloat bgAlpha = [self alphaForUIColor:view.backgroundColor];
    if (bgAlpha > kAlphaEpsilon) {
        return YES;
    }
    if (view.layer.backgroundColor) {
        CGFloat layerBGAlpha = CGColorGetAlpha(view.layer.backgroundColor);
        if (layerBGAlpha > kAlphaEpsilon) {
            return YES;
        }
    }
    
    // Known classes
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        return YES;
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        if (iv.image != nil) {
            return YES;
        }
    }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text.length > 0 && [self alphaForUIColor:label.textColor] > kAlphaEpsilon) {
            return YES;
        }
    }
    if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.text.length > 0 && [self alphaForUIColor:tv.textColor] > kAlphaEpsilon) {
            return YES;
        }
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        if (btn.currentImage || btn.currentBackgroundImage) {
            return YES;
        }
        UIColor *titleColor = [btn titleColorForState:UIControlStateNormal];
        NSString *title = [btn titleForState:UIControlStateNormal];
        if (title.length > 0 && [self alphaForUIColor:titleColor] > kAlphaEpsilon) {
            return YES;
        }
    }
    Class wkClass = [NativoViewExposureChecker wkWebViewClass];
    if (wkClass && [view isKindOfClass:wkClass]) {
        return YES;
    }
    
    // Layer content: if layer has contents or sublayers with contents, assume it draws
    if (view.layer.contents != nil) {
        return YES;
    }
    if (view.layer.sublayers.count > 0) {
        for (CALayer *sublayer in view.layer.sublayers) {
            if (sublayer.opacity > kAlphaEpsilon) {
                if (sublayer.backgroundColor && CGColorGetAlpha(sublayer.backgroundColor) > kAlphaEpsilon) {
                    return YES;
                }
                if (sublayer.contents != nil) {
                    return YES;
                }
            }
        }
    }
    
    // Default: assume this view itself does not draw opaque content
    return NO;
}

// return 'NO' if exposure is zero
- (BOOL)visitParent:(UIView *)parentView fromChild:(UIView *)childView {
    if (parentView.isHidden) {
        return NO;
    }
    BOOL const clip = parentView.clipsToBounds || (parentView == self.testedView.window);
    if (clip) {
        self.clippedRect = CGRectIntersection(self.clippedRect, [self.testedView convertRect:parentView.bounds fromView:parentView]);
        if (CGRectIsEmpty(self.clippedRect)) {
            return NO;
        }
    }
    
    if (parentView.superview != nil) {
        BOOL notOverclipped = [self visitParent:parentView.superview fromChild:parentView];
        if (!notOverclipped) {
            return NO;
        }
    }
    
    NSArray<UIView *> *subViews = [parentView subviews];
    for(NSUInteger i = [subViews indexOfObject:childView] + 1, n = subViews.count; i < n; i++) {
        // Pass the current clip down to children
        [self collectObstructionsFrom:subViews[i] withClip:self.clippedRect];
    }
    return YES;
}

// Optimized traversal: compute conversion/intersection once per node and thread current clip down
- (void)collectObstructionsFrom:(UIView *)view withClip:(CGRect)currentClipInTestedCoords {
    // Basic hidden/alpha/zero/window checks
    if ([self isEffectivelyHidden:view]) {
        return;
    }
    
    // Compute this view's rect in testedView coordinates once
    CGRect viewRectInTested = [self.testedView convertRect:view.bounds fromView:view];
    // Intersect with the current clip
    CGRect intersection = CGRectIntersection(currentClipInTestedCoords, viewRectInTested);
    if (CGRectIsEmpty(intersection)) {
        return;
    }
    
    // If the view contributes opaque content, add its intersecting rect as an obstruction
    if ([self viewHasOpaqueVisualContent:view]) {
        [self.obstructions addObject:@(intersection)];
        // If this view clipsToBounds, children outside its bounds cannot add more; we can still traverse
        // inside if we want subviews that extend beyond parent but are clipped anyway; however, adding
        // them won't change obstruction since we've already added full intersection. So we can exit early.
        if (view.clipsToBounds) {
            return;
        }
        // Else, its subviews might extend beyond and cause more obstruction; continue traversal.
    }
    
    // Recurse into children
    // Decide the clip to pass to children:
    // - If parent clips, use intersection (children cannot draw outside)
    // - If parent doesn't clip, we can pass the existing current clip (children may extend beyond parent)
    CGRect nextClip = view.clipsToBounds ? intersection : currentClipInTestedCoords;
    for (UIView *subView in view.subviews) {
        [self collectObstructionsFrom:subView withClip:nextClip];
    }
}

// Backwards-compatible shim for existing callers
- (void)collectObstructionsFrom:(UIView *)view {
    [self collectObstructionsFrom:view withClip:self.clippedRect];
}

// return 'YES' if resulted in non-empty rect
- (BOOL)collapseBoundingBox {
    CGRect const oldRect = self.clippedRect;
    if (CGRectIsEmpty(oldRect)) {
        return NO;
    }
    
    NSMutableArray<NSValue *> *currentRects = [[NSMutableArray alloc] init];
    NSMutableArray<NSValue *> *nextRects = [[NSMutableArray alloc] init];
    
    [currentRects addObject:@(self.clippedRect)];
    for(NSValue *obstruction in self.obstructions) {
        [self removeRect:obstruction.CGRectValue from:currentRects into:nextRects startingWith:0];
        
        // swap currentRects and nextRects to avoid excessive allocations
        do {
            NSMutableArray<NSValue *> *t = currentRects;
            currentRects = nextRects;
            nextRects = t;
            [nextRects removeAllObjects];
        } while(NO);
        
        if (currentRects.count == 0) {
            self.clippedRect = CGRectZero;
            return NO;
        }
    }
    
    BOOL first = YES;
    CGRect result = CGRectZero;
    for(NSValue *nextFragment in currentRects) {
        if (first) {
            first = NO;
            result = nextFragment.CGRectValue;
        } else {
            result = CGRectUnion(result, nextFragment.CGRectValue);
        }
    }
    
    if (CGRectEqualToRect(oldRect, result)) {
        return YES;
    }
    
    self.clippedRect = result;
    
    NSUInteger removedCount = 0;
    NSUInteger const fullCount = self.obstructions.count;
    for(NSUInteger i = 0; i < fullCount; i++) {
        NSValue *nextObstruction = self.obstructions[i];
        CGRect const testRect = nextObstruction.CGRectValue;
        if (CGRectIntersectsRect(testRect, result)) {
            if (!CGRectContainsRect(result, testRect)) {
                [self.obstructions replaceObjectAtIndex:(i - removedCount) withObject:@(CGRectIntersection(result, testRect))];
            } else if (removedCount) {
                [self.obstructions replaceObjectAtIndex:(i - removedCount) withObject:nextObstruction];
            };
        } else {
            removedCount++;
        }
    }
    if (removedCount) {
        [self.obstructions removeObjectsInRange:NSMakeRange(fullCount - removedCount, removedCount)];
    }
    
    return YES;
}

- (void)removeRect:(CGRect)rect from:(NSArray<NSValue *> *)srcArray into:(NSMutableArray<NSValue *> *)dstArray startingWith:(NSUInteger)firstIndex {
    for(NSUInteger i = firstIndex, n = srcArray.count; i < n; i++) {
        [self fragmentize:srcArray[i] aroundRect:rect into:dstArray];
    }
}

- (NSArray<NSValue *> *)buildObstructionRects {
    if (self.obstructions.count == 0) {
        return nil;
    }
    
    NSMutableArray<NSValue *> *currentObstructions = [self.obstructions mutableCopy];
    NSMutableArray<NSValue *> *remainingObstructions = [[NSMutableArray alloc] init];
    NSMutableArray<NSValue *> * const pickedObstructions = [[NSMutableArray alloc] init];
    
    NSComparator areaComparator = ^NSComparisonResult(NSValue *rect1, NSValue *rect2) {
        CGSize const size1 = rect1.CGRectValue.size;
        float const area1 = size1.width * size1.height;
        CGSize const size2 = rect2.CGRectValue.size;
        float const area2 = size2.width * size2.height;
        NSComparisonResult result = (area1 < area2) ? NSOrderedAscending : ((area1 > area2) ? NSOrderedDescending : NSOrderedSame);
        return -result; // invert order -- sort from largest rect to smallest
    };
    
    while(currentObstructions.count > 0) {
        // pick largest obstruction
        [currentObstructions sortUsingComparator:areaComparator];
        NSValue * const nextPicked = [currentObstructions firstObject];
        [pickedObstructions addObject:nextPicked];
        
        // copy others to remaining, after cutting out the picked area
        [self removeRect:nextPicked.CGRectValue from:currentObstructions into:remainingObstructions startingWith:1];
        
        // swap currentObstructions and remainingObstructions to avoid excessive allocations
        do {
            NSMutableArray<NSValue *> *t = currentObstructions;
            currentObstructions = remainingObstructions;
            remainingObstructions = t;
            [remainingObstructions removeAllObjects];
        } while(NO);
    }
    
    return pickedObstructions.count > 0 ? pickedObstructions : nil;
}

- (void)fragmentize:(NSValue *)value aroundRect:(CGRect)rect into:(NSMutableArray<NSValue *> *)array {
    CGRect const valRect = value.CGRectValue;
    if (!CGRectIntersectsRect(valRect, rect)) {
        [array addObject:value];
        return;
    }
    if (CGRectContainsRect(rect, valRect)) {
        return;
    }
    CGRect const trimmedRect = CGRectIntersection(rect, valRect);
    CGRect subRects[] = {
        // left
        CGRectMake(CGRectGetMinX(valRect),
                   CGRectGetMinY(valRect),
                   CGRectGetMinX(trimmedRect) - CGRectGetMinX(valRect),
                   CGRectGetHeight(valRect)),
        
        // mid/top
        CGRectMake(CGRectGetMinX(trimmedRect),
                   CGRectGetMinY(valRect),
                   CGRectGetWidth(trimmedRect),
                   CGRectGetMinY(trimmedRect) - CGRectGetMinY(valRect)),
        
        // mid/bottom
        CGRectMake(CGRectGetMinX(trimmedRect),
                   CGRectGetMaxY(trimmedRect),
                   CGRectGetWidth(trimmedRect),
                   CGRectGetMaxY(valRect) - CGRectGetMaxY(trimmedRect)),
        
        // right
        CGRectMake(CGRectGetMaxX(trimmedRect),
                   CGRectGetMinY(valRect),
                   CGRectGetMaxX(valRect) - CGRectGetMaxX(trimmedRect),
                   CGRectGetHeight(valRect)),
    };
    for(int i = 0; i < 4; i++) {
        if (!CGRectIsEmpty(subRects[i])) {
            [array addObject:@(subRects[i])];
        }
    }
}

@end

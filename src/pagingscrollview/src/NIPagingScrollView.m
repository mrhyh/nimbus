//
// Copyright 2011 Jeff Verkoeyen
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "NIPagingScrollView.h"

#import "NIPagingScrollViewPage.h"
#import "NIPagingScrollViewDataSource.h"
#import "NIPagingScrollViewDelegate.h"
#import "NimbusCore.h"

const NSInteger NIPagingScrollViewUnknownNumberOfPages = -1;
const CGFloat NIPagingScrollViewDefaultPageHorizontalMargin = 10;


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
@implementation NIPagingScrollView

@synthesize pageClass = _pageClass;
@synthesize pageHorizontalMargin = _pageHorizontalMargin;
@synthesize dataSource = _dataSource;
@synthesize delegate = _delegate;
@synthesize centerPageIndex = _centerPageIndex;
@synthesize numberOfPages = _numberOfPages;


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)dealloc {
  _pagingScrollView = nil;

  NI_RELEASE_SAFELY(_visiblePages);
  NI_RELEASE_SAFELY(_recycledPages);

  [super dealloc];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (id)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    // Default state.
    self.pageHorizontalMargin = NIPagingScrollViewDefaultPageHorizontalMargin;

    _firstVisiblePageIndexBeforeRotation = -1;
    _percentScrolledIntoFirstVisiblePage = -1;
    _centerPageIndex = -1;
    _numberOfPages = NIPagingScrollViewUnknownNumberOfPages;

    _pagingScrollView = [[[UIScrollView alloc] initWithFrame:frame] autorelease];
    _pagingScrollView.pagingEnabled = YES;

    _pagingScrollView.autoresizingMask = (UIViewAutoresizingFlexibleWidth
                                          | UIViewAutoresizingFlexibleHeight);

    _pagingScrollView.delegate = self;

    // Ensure that empty areas of the scroll view are draggable.
    _pagingScrollView.backgroundColor = [UIColor blackColor];

    _pagingScrollView.showsVerticalScrollIndicator = NO;
    _pagingScrollView.showsHorizontalScrollIndicator = NO;

    [self addSubview:_pagingScrollView];
  }
  return self;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Page Layout


// The following three methods are from Apple's ImageScrollView example application and have
// been used here because they are well-documented and concise.


///////////////////////////////////////////////////////////////////////////////////////////////////
- (CGRect)frameForPagingScrollView {
  CGRect frame = self.bounds;

  // We make the paging scroll view a little bit wider on the side edges so that there
  // there is space between the pages when flipping through them.
  frame.origin.x -= self.pageHorizontalMargin;
  frame.size.width += (2 * self.pageHorizontalMargin);

  return frame;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (CGRect)frameForPageAtIndex:(NSInteger)pageIndex {
  // We have to use our paging scroll view's bounds, not frame, to calculate the page
  // placement. When the device is in landscape orientation, the frame will still be in
  // portrait because the pagingScrollView is the root view controller's view, so its
  // frame is in window coordinate space, which is never rotated. Its bounds, however,
  // will be in landscape because it has a rotation transform applied.
  CGRect bounds = _pagingScrollView.bounds;
  CGRect pageFrame = bounds;

  // We need to counter the extra spacing added to the paging scroll view in
  // frameForPagingScrollView:
  pageFrame.size.width -= self.pageHorizontalMargin * 2;
  pageFrame.origin.x = (bounds.size.width * pageIndex) + self.pageHorizontalMargin;

  return pageFrame;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (CGSize)contentSizeForPagingScrollView {
  // We have to use the paging scroll view's bounds to calculate the contentSize, for the
  // same reason outlined above.
  CGRect bounds = _pagingScrollView.bounds;
  return CGSizeMake(bounds.size.width * _numberOfPages, bounds.size.height);
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Visible Page Management


///////////////////////////////////////////////////////////////////////////////////////////////////
- (id<NIPagingScrollViewPage>)dequeueRecycledPage {
  id<NIPagingScrollViewPage> page = [_recycledPages anyObject];

  if (nil != page) {
    // Ensure that this page sticks around for this runloop.
    [[page retain] autorelease];

    [_recycledPages removeObject:page];

    // Reset this page to a blank slate state.
    [page prepareForReuse];
  }

  return page;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (BOOL)isDisplayingPageForIndex:(NSInteger)pageIndex {
  BOOL foundPage = NO;

  // There will never be more than 3 visible pages in this array, so this lookup is
  // effectively O(C) constant time.
  for (id<NIPagingScrollViewPage> page in _visiblePages) {
    if (page.pageIndex == pageIndex) {
      foundPage = YES;
      break;
    }
  }

  return foundPage;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (NSInteger)currentVisiblePageIndex {
  CGPoint contentOffset = _pagingScrollView.contentOffset;
  CGSize boundsSize = _pagingScrollView.bounds.size;

  // Whatever image is currently displayed in the center of the screen is the currently
  // visible image.
  return boundi((NSInteger)(floorf((contentOffset.x + boundsSize.width / 2) / boundsSize.width)
                            + 0.5f),
                0, self.numberOfPages);
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (NSRange)visiblePageRange {
  if (0 >= _numberOfPages) {
    return NSMakeRange(0, 0);
  }

  NSInteger currentVisiblePageIndex = [self currentVisiblePageIndex];

  int firstVisiblePageIndex = boundi(currentVisiblePageIndex - 1, 0, _numberOfPages - 1);
  int lastVisiblePageIndex  = boundi(currentVisiblePageIndex + 1, 0, _numberOfPages - 1);

  return NSMakeRange(firstVisiblePageIndex, lastVisiblePageIndex - firstVisiblePageIndex + 1);
}



///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)configurePage:(id<NIPagingScrollViewPage>)page forIndex:(NSInteger)pageIndex {
  page.pageIndex = pageIndex;
  page.frame = [self frameForPageAtIndex:pageIndex];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)resetPage:(id<NIPagingScrollViewPage>)page {
  [page pageDidDisappear];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)resetSurroundingPages {
  for (id<NIPagingScrollViewPage> page in _visiblePages) {
    if (page.pageIndex != self.centerPageIndex) {
      [self resetPage:page];
    }
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)displayPageAtIndex:(NSInteger)pageIndex {
  id<NIPagingScrollViewPage> page = [self dequeueRecycledPage];

  if (nil == page) {
    page = (id<NIPagingScrollViewPage>)[[[[self pageClass] alloc] init] autorelease];
    NIDASSERT([page isKindOfClass:[UIView class]]);
    NIDASSERT([page conformsToProtocol:@protocol(NIPagingScrollViewPage)]);
  }

  // This will only be called once before the page is shown.
  [self configurePage:page forIndex:pageIndex];

  [_pagingScrollView addSubview:(UIView *)page];
  [_visiblePages addObject:page];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)updateVisiblePages {
  NSInteger oldCenterPageIndex = self.centerPageIndex;

  NSRange visiblePageRange = [self visiblePageRange];

  _centerPageIndex = [self currentVisiblePageIndex];

  // Recycle no-longer-visible pages.
  for (id<NIPagingScrollViewPage> page in _visiblePages) {
    if (!NSLocationInRange(page.pageIndex, visiblePageRange)) {
      [_recycledPages addObject:page];
      [page removeFromSuperview];
    }
  }
  [_visiblePages minusSet:_recycledPages];

  // Prioritize displaying the currently visible page.
  if (![self isDisplayingPageForIndex:_centerPageIndex]) {
    [self displayPageAtIndex:_centerPageIndex];
  }

  // Add missing pages.
  for (int pageIndex = visiblePageRange.location;
       pageIndex < NSMaxRange(visiblePageRange); ++pageIndex) {
    if (![self isDisplayingPageForIndex:pageIndex]) {
      [self displayPageAtIndex:pageIndex];
    }
  }

  if (oldCenterPageIndex != _centerPageIndex
      && [self.delegate respondsToSelector:@selector(pagingScrollViewDidChangePages:)]) {
    [self.delegate pagingScrollViewDidChangePages:self];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark UIView


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)setFrame:(CGRect)frame {
  // We have to modify this method because it eventually leads to changing the content offset
  // programmatically. When this happens we end up getting a scrollViewDidScroll: message
  // during which we do not want to modify the visible pages because this is handled elsewhere.
  
  
  // Don't lose the previous modification state if an animation is occurring when the
  // frame changes, like when the device changes orientation.
  BOOL wasModifyingContentOffset = _isModifyingContentOffset;
  _isModifyingContentOffset = YES;
  [super setFrame:frame];
  _isModifyingContentOffset = wasModifyingContentOffset;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark UIScrollViewDelegate


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  if (!_isModifyingContentOffset) {
    // This method is called repeatedly as the user scrolls so updateVisiblePages must be
    // light-weight enough not to noticeably impact performance.
    [self updateVisiblePages];
  }

  if ([self.delegate respondsToSelector:@selector(scrollViewDidScroll:)]) {
    [self.delegate scrollViewDidScroll:scrollView];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
  if (!decelerate) {
    [self resetSurroundingPages];
  }

  if ([self.delegate respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
    [self.delegate scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
  [self resetSurroundingPages];
  
  if ([self.delegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
    [self.delegate scrollViewDidEndDecelerating:scrollView];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Public Methods


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)reloadData {
  NIDASSERT(nil != _dataSource);

  // Remove any visible pages from the view before we release the sets.
  for (id<NIPagingScrollViewPage> page in _visiblePages) {
    [page removeFromSuperview];
  }

  NI_RELEASE_SAFELY(_visiblePages);
  NI_RELEASE_SAFELY(_recycledPages);

  // Reset the state of the scroll view.
  _isModifyingContentOffset = YES;
  _pagingScrollView.contentSize = self.bounds.size;
  _pagingScrollView.contentOffset = CGPointZero;
  _isModifyingContentOffset = NO;
  _centerPageIndex = -1;

  // If there is no data source then we can't do anything particularly interesting.
  if (nil == _dataSource) {
    return;
  }

  _visiblePages = [[NSMutableSet alloc] init];
  _recycledPages = [[NSMutableSet alloc] init];

  // Cache the number of pages.
  _numberOfPages = [_dataSource numberOfPagesInPageScrollView:self];

  _pagingScrollView.frame = [self frameForPagingScrollView];

  // The content size is calculated based on the number of pages and the scroll view frame.
  _pagingScrollView.contentSize = [self contentSizeForPagingScrollView];

  // Begin requesting the page information from the data source.
  [self updateVisiblePages];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)willRotateToInterfaceOrientation: (UIInterfaceOrientation)toInterfaceOrientation
                                duration: (NSTimeInterval)duration {
  // Here, our pagingScrollView bounds have not yet been updated for the new interface
  // orientation. This is a good place to calculate the content offset that we will
  // need in the new orientation.
  CGFloat offset = _pagingScrollView.contentOffset.x;
  CGFloat pageWidth = _pagingScrollView.bounds.size.width;

  if (offset >= 0) {
    _firstVisiblePageIndexBeforeRotation = floorf(offset / pageWidth);
    _percentScrolledIntoFirstVisiblePage = ((offset
                                            - (_firstVisiblePageIndexBeforeRotation * pageWidth))
                                           / pageWidth);

  } else {
    _firstVisiblePageIndexBeforeRotation = 0;
    _percentScrolledIntoFirstVisiblePage = offset / pageWidth;
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)willAnimateRotationToInterfaceOrientation: (UIInterfaceOrientation)toInterfaceOrientation
                                         duration: (NSTimeInterval)duration {
  BOOL wasModifyingContentOffset = _isModifyingContentOffset;

  // Recalculate contentSize based on current orientation.
  _isModifyingContentOffset = YES;
  _pagingScrollView.contentSize = [self contentSizeForPagingScrollView];
  _isModifyingContentOffset = wasModifyingContentOffset;

  // adjust frames and configuration of each visible page.
  for (id<NIPagingScrollViewPage> page in _visiblePages) {
    [page setFrameAndMaintainZoomAndCenter:[self frameForPageAtIndex:page.pageIndex]];
  }

  // Adjust contentOffset to preserve page location based on values collected prior to location.
  CGFloat pageWidth = _pagingScrollView.bounds.size.width;
  CGFloat newOffset = ((_firstVisiblePageIndexBeforeRotation * pageWidth)
                       + (_percentScrolledIntoFirstVisiblePage * pageWidth));
  _isModifyingContentOffset = YES;
  _pagingScrollView.contentOffset = CGPointMake(newOffset, 0);
  _isModifyingContentOffset = wasModifyingContentOffset;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (BOOL)hasNext {
  return (self.centerPageIndex < self.numberOfPages - 1);
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (BOOL)hasPrevious {
  return self.centerPageIndex > 0;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)didAnimateToPage:(NSNumber *)pageIndex {
  _isAnimatingToPage = NO;

  // Reset the content offset once the animation completes, just to be sure that the
  // viewer sits on a page bounds even if we rotate the device while animating.
  CGPoint offset = [self frameForPageAtIndex:[pageIndex intValue]].origin;
  offset.x -= self.pageHorizontalMargin;

  _isModifyingContentOffset = YES;
  _pagingScrollView.contentOffset = offset;
  _isModifyingContentOffset = NO;

  [self updateVisiblePages];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)moveToPageAtIndex:(NSInteger)pageIndex animated:(BOOL)animated {
  if (_isAnimatingToPage) {
    // Don't allow re-entry for sliding animations.
    return;
  }

  CGPoint offset = [self frameForPageAtIndex:pageIndex].origin;
  offset.x -= self.pageHorizontalMargin;

  _isModifyingContentOffset = YES;
  [_pagingScrollView setContentOffset:offset animated:animated];

  NSNumber* pageIndexNumber = [NSNumber numberWithInt:pageIndex];
  if (animated) {
    _isAnimatingToPage = YES;
    SEL selector = @selector(didAnimateToPage:);
    [NSObject cancelPreviousPerformRequestsWithTarget: self];

    // When the animation is finished we reset the content offset just in case the frame
    // changes while we're animating (like when rotating the device). To do this we need
    // to know the destination index for the animation.
    [self performSelector: selector
               withObject: pageIndexNumber
               afterDelay: 0.4];

  } else {
    [self didAnimateToPage:pageIndexNumber];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)moveToNextAnimated:(BOOL)animated {
  if ([self hasNext]) {
    NSInteger pageIndex = self.centerPageIndex + 1;

    [self moveToPageAtIndex:pageIndex animated:animated];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)moveToPreviousAnimated:(BOOL)animated {
  if ([self hasPrevious]) {
    NSInteger pageIndex = self.centerPageIndex - 1;

    [self moveToPageAtIndex:pageIndex animated:animated];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)setCenterPageIndex:(NSInteger)centerPageIndex animated:(BOOL)animated {
  [self moveToPageAtIndex:centerPageIndex animated:animated];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)setCenterPageIndex:(NSInteger)centerPageIndex {
  [self setCenterPageIndex:centerPageIndex animated:NO];
}


@end

#import "ViTextView.h"
#import "ViBundleStore.h"
#import "ViThemeStore.h"
#import "ViDocument.h"  // for declaration of the message: method
#import "NSString-scopeSelector.h"
#import "NSString-additions.h"
#import "NSArray-patterns.h"
#import "ViAppController.h"  // for sharedBuffers
#import "ViDocumentView.h"
#import "ViJumpList.h"
#import "NSObject+SPInvocationGrabbing.h"
#import "ViMark.h"
#import "ViCommandMenuItemView.h"
#import "NSScanner-additions.h"
#import "NSEvent-keyAdditions.h"
#import "ViError.h"
#import "ViRegisterManager.h"
#import "ViLayoutManager.h"

int logIndent = 0;

@interface ViTextView (private)
- (void)recordReplacementOfRange:(NSRange)aRange withLength:(NSUInteger)aLength;
- (NSArray *)smartTypingPairsAtLocation:(NSUInteger)aLocation;
- (BOOL)normal_mode:(ViCommand *)command;
- (void)replaceCharactersInRange:(NSRange)aRange
                      withString:(NSString *)aString
                       undoGroup:(BOOL)undoGroup;
- (void)setVisualSelection;
- (void)updateStatus;
- (NSUInteger)removeTrailingAutoIndentForLineAtLocation:(NSUInteger)aLocation;
@end

#pragma mark -

@implementation ViTextView

@synthesize proxy;
@synthesize keyManager;
@synthesize document;

- (void)initWithDocument:(ViDocument *)aDocument viParser:(ViParser *)aParser
{
	[self setCaret:0];

	keyManager = [[ViKeyManager alloc] initWithTarget:self
					       parser:aParser];

	document = aDocument;
	undoManager = [document undoManager];
	if (undoManager == nil)
		undoManager = [[NSUndoManager alloc] init];
	inputKeys = [NSMutableArray array];
	marks = [NSMutableDictionary dictionary];
	saved_column = -1;
	snippetMatchRange.location = NSNotFound;

	wordSet = [NSMutableCharacterSet characterSetWithCharactersInString:@"_"];
	[wordSet formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
	whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

	nonWordSet = [[NSMutableCharacterSet alloc] init];
	[nonWordSet formUnionWithCharacterSet:wordSet];
	[nonWordSet formUnionWithCharacterSet:whitespace];
	[nonWordSet invert];

	[self setRichText:NO];
	[self setImportsGraphics:NO];
	[self setAutomaticDashSubstitutionEnabled:NO];
	[self setAutomaticDataDetectionEnabled:NO];
	[self setAutomaticLinkDetectionEnabled:NO];
	[self setAutomaticQuoteSubstitutionEnabled:NO];
	[self setAutomaticSpellingCorrectionEnabled:NO];
	[self setContinuousSpellCheckingEnabled:NO];
	[self setGrammarCheckingEnabled:NO];
	[self setDisplaysLinkToolTips:NO];
	[self setSmartInsertDeleteEnabled:NO];
	[self setAutomaticTextReplacementEnabled:NO];
	[self setUsesFindPanel:YES];
	[self setUsesFontPanel:NO];
	if (document) {
		/* FIXME: change wrap setting if language changes. */
		NSString *scope = [[document language] name];
		NSInteger wrap = 1;
		if (scope) {
			NSArray *langScope = [NSArray arrayWithObject:scope];
			wrap = [[self preference:@"wrap" forScope:langScope] integerValue];
		} else {
			wrap = [[NSUserDefaults standardUserDefaults] boolForKey:@"wrap"];
		}
		[self setWrapping:wrap];
	}
	[self setDrawsBackground:YES];

	DEBUG(@"got %lu lines", [[self textStorage] lineCount]);
	if ([[self textStorage] lineCount] > 3000)
		[[self layoutManager] setAllowsNonContiguousLayout:YES];
	else
		[[self layoutManager] setAllowsNonContiguousLayout:NO];

	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"theme"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];
	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"antialias"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];
	antialias = [[NSUserDefaults standardUserDefaults] boolForKey:@"antialias"];

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(textStorageDidChangeLines:)
						     name:ViTextStorageChangedLinesNotification 
						   object:[self textStorage]];

	[self setTheme:[[ViThemeStore defaultStore] defaultTheme]];
	proxy = [[ViScriptProxy alloc] initWithObject:self];
	[self updateStatus];
}

- (ViTextStorage *)textStorage
{
	return (ViTextStorage *)[super textStorage];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
		      ofObject:(id)object
			change:(NSDictionary *)change
		       context:(void *)context
{
	if ([keyPath isEqualToString:@"antialias"]) {
		antialias = [[NSUserDefaults standardUserDefaults] boolForKey:keyPath];
		[self setNeedsDisplayInRect:[self bounds]];
	} else if ([keyPath isEqualToString:@"theme"]) {
		/*
		 * Change the theme and invalidate all layout.
		 */
		ViTheme *theme = [[ViThemeStore defaultStore] themeWithName:[change objectForKey:NSKeyValueChangeNewKey]];
		[self setTheme:theme];
		ViLayoutManager *lm = (ViLayoutManager *)[self layoutManager];
		[lm setInvisiblesAttributes:[theme invisiblesAttributes]];
		[lm invalidateDisplayForCharacterRange:NSMakeRange(0, [[self textStorage] length])];
	}
}

- (void)textStorageDidChangeLines:(NSNotification *)notification
{
	/*
	 * Don't enable non-contiguous layout unless we have a huge document.
	 * It's buggy and annoying, but layout is unusable on huge documents otherwise...
	 */
	DEBUG(@"got %lu lines", [[self textStorage] lineCount]);
	if ([self isFieldEditor])
		return;
	if ([[self textStorage] lineCount] > 3000)
		[[self layoutManager] setAllowsNonContiguousLayout:YES];
	else
		[[self layoutManager] setAllowsNonContiguousLayout:NO];
}

- (void)rulerView:(NSRulerView *)aRulerView
  selectFromPoint:(NSPoint)fromPoint
          toPoint:(NSPoint)toPoint
{
	NSInteger fromIndex = [self characterIndexForInsertionAtPoint:fromPoint];
	if (fromIndex == NSNotFound)
		return;

	NSInteger toIndex = [self characterIndexForInsertionAtPoint:toPoint];
	if (toIndex == NSNotFound)
		return;

	if (keyManager.parser.partial) {
		MESSAGE(@"Vi command interrupted.");
		[keyManager.parser reset];
	}

	visual_start_location = fromIndex;
	visual_line_mode = YES;
	end_location = toIndex;

	[self setVisualMode];
	[self setCaret:toIndex];
	[self setVisualSelection];
}

- (void)copy:(id)sender
{
	[keyManager handleKeys:[@"\"+y" keyCodes]];
}

- (void)paste:(id)sender
{
	[keyManager handleKeys:[@"\"+P" keyCodes]];
}

- (void)cut:(id)sender
{
	[keyManager handleKeys:[@"\"+x" keyCodes]];
}

- (BOOL)shouldChangeTextInRanges:(NSArray *)affectedRanges
              replacementStrings:(NSArray *)replacementStrings
{
	/*
	 * If called by [super keyDown], just return yes.
	 * This allows us to type dead keys.
	 */
	if (handlingKey)
		return YES;

	/*
	 * Otherwise it's called from somewhere else, typically by
	 * dragging and dropping text, or using an input manager.
	 * We handle it ourselves, and return NO.
	 */

	[self beginUndoGroup];

	NSUInteger i;
	for (i = 0; i < [affectedRanges count]; i++) {
		NSRange range = [[affectedRanges objectAtIndex:i] rangeValue];
		NSString *string = [replacementStrings objectAtIndex:i];
		[self replaceCharactersInRange:range withString:string undoGroup:NO];
	}

	[self endUndoGroup];

	return NO;
}

- (void)setMark:(unichar)name atLocation:(NSUInteger)aLocation
{
	NSUInteger lineno = [[self textStorage] lineNumberAtLocation:aLocation];
	NSUInteger column = [[self textStorage] columnAtLocation:aLocation];
	ViMark *m = [[ViMark alloc] initWithLine:lineno column:column];
	[marks setObject:m forKey:[NSString stringWithFormat:@"%C", name]];
}

#pragma mark -
#pragma mark Convenience methods

- (void)getLineStart:(NSUInteger *)bol_ptr
                 end:(NSUInteger *)end_ptr
         contentsEnd:(NSUInteger *)eol_ptr
         forLocation:(NSUInteger)aLocation
{
	if ([[self textStorage] length] == 0) {
		if (bol_ptr != NULL)
			*bol_ptr = 0;
		if (end_ptr != NULL)
			*end_ptr = 0;
		if (eol_ptr != NULL)
			*eol_ptr = 0;
	} else
		[[[self textStorage] string] getLineStart:bol_ptr
		                                      end:end_ptr
		                              contentsEnd:eol_ptr
		                                 forRange:NSMakeRange(aLocation, 0)];
}

- (void)getLineStart:(NSUInteger *)bol_ptr
                 end:(NSUInteger *)end_ptr
         contentsEnd:(NSUInteger *)eol_ptr
{
	[self getLineStart:bol_ptr
	               end:end_ptr
	       contentsEnd:eol_ptr
	       forLocation:start_location];
}

- (void)setString:(NSString *)aString
{
	NSRange r = NSMakeRange(0, [[self textStorage] length]);
	[[self textStorage] replaceCharactersInRange:r
	                                  withString:aString];
	NSDictionary *attrs = [self typingAttributes];
	if (attrs) {
		r = NSMakeRange(0, [[self textStorage] length]);
		[[self textStorage] setAttributes:attrs
					    range:r];
	}
}

- (void)replaceCharactersInRange:(NSRange)aRange
                      withString:(NSString *)aString
                       undoGroup:(BOOL)undoGroup
{
	modify_start_location = aRange.location;

	ViSnippet *snippet = document.snippet;
	if (snippet) {
		/* Let the snippet drive the changes. */
		if ([snippet replaceRange:aRange withString:aString])
			return;
		[self cancelSnippet:snippet];
	}

	if (undoGroup)
		[self beginUndoGroup];

	[self recordReplacementOfRange:aRange withLength:[aString length]];
	[[self textStorage] replaceCharactersInRange:aRange withString:aString];
	NSRange r = NSMakeRange(aRange.location, [aString length]);
	[[self textStorage] setAttributes:[self typingAttributes]
	                            range:r];

	[self setMark:'.' atLocation:aRange.location];
}

- (void)replaceCharactersInRange:(NSRange)aRange withString:(NSString *)aString
{
	[self replaceCharactersInRange:aRange withString:aString undoGroup:YES];
}

/* Like insertText:, but works within beginEditing/endEditing.
 * Also begins an undo group.
 */
- (void)insertString:(NSString *)aString
          atLocation:(NSUInteger)aLocation
           undoGroup:(BOOL)undoGroup
{
	[self replaceCharactersInRange:NSMakeRange(aLocation, 0) withString:aString undoGroup:undoGroup];
}

- (void)insertString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	[self insertString:aString atLocation:aLocation undoGroup:YES];
}

- (void)insertString:(NSString *)aString
{
	[self insertString:aString atLocation:[self caret] undoGroup:YES];
}

- (void)deleteRange:(NSRange)aRange undoGroup:(BOOL)undoGroup
{
	[self replaceCharactersInRange:aRange withString:@"" undoGroup:undoGroup];
}

- (void)deleteRange:(NSRange)aRange
{
	[self deleteRange:aRange undoGroup:NO];
}

- (void)replaceRange:(NSRange)aRange withString:(NSString *)aString undoGroup:(BOOL)undoGroup
{
	[self replaceCharactersInRange:aRange withString:aString undoGroup:undoGroup];
}

- (void)replaceRange:(NSRange)aRange withString:(NSString *)aString
{
	[self replaceRange:aRange withString:aString undoGroup:YES];
}

- (void)snippet:(ViSnippet *)snippet replaceCharactersInRange:(NSRange)aRange withString:(NSString *)aString
{
	DEBUG(@"replace range %@ with [%@]", NSStringFromRange(aRange), aString);
	[self beginUndoGroup];
	[self recordReplacementOfRange:aRange withLength:[aString length]];
	[[self textStorage] replaceCharactersInRange:aRange withString:aString];
	NSRange r = NSMakeRange(aRange.location, [aString length]);
	[[self textStorage] setAttributes:[self typingAttributes]
	                            range:r];

	if (modify_start_location > NSMaxRange(r)) {
		NSInteger delta = [aString length] - aRange.length;
		DEBUG(@"modify_start_location %lu -> %lu", modify_start_location, modify_start_location + delta);
		modify_start_location += delta;
	}
}

- (NSArray *)scopesAtLocation:(NSUInteger)aLocation
{
	if (aLocation >= [[self textStorage] length]) {
		/* use document scope at EOF */
		DEBUG(@"document language is %@ (%@)", [document language], [[document language] name]);
		NSString *scope = [[document language] name];
		return scope ? [NSArray arrayWithObject:scope] : nil;
	}
	return [document scopesAtLocation:aLocation];
}

#pragma mark -
#pragma mark Indentation

- (NSString *)indentStringOfLength:(NSInteger)length
{
	length = IMAX(length, 0);
	NSInteger tabstop = [[self preference:@"tabstop"] integerValue];
	if ([[self preference:@"expandtab"] integerValue] == NSOnState) {
		// length * " "
		return [@"" stringByPaddingToLength:length withString:@" " startingAtIndex:0];
	} else {
		// length / tabstop * "tab" + length % tabstop * " "
		NSInteger ntabs = (length / tabstop);
		NSInteger nspaces = (length % tabstop);
		NSString *indent = [@"" stringByPaddingToLength:ntabs withString:@"\t" startingAtIndex:0];
		return [indent stringByPaddingToLength:ntabs + nspaces withString:@" " startingAtIndex:0];
	}
}

- (NSUInteger)lengthOfIndentString:(NSString *)indent
{
	NSInteger tabstop = [[self preference:@"tabstop"] integerValue];
	NSUInteger i;
	NSUInteger length = 0;
	for (i = 0; i < [indent length]; i++)
	{
		unichar c = [indent characterAtIndex:i];
		if (c == ' ')
			++length;
		else if (c == '\t')
			length += tabstop - (length % tabstop);
	}

	return length;
}

- (NSUInteger)lengthOfIndentAtLocation:(NSUInteger)aLocation
{
	return [self lengthOfIndentString:[[self textStorage] leadingWhitespaceForLineAtLocation:aLocation]];
}

- (BOOL)shouldIncreaseIndentAtLocation:(NSUInteger)aLocation
{
	NSDictionary *increaseIndentPatterns = [[ViBundleStore defaultStore] preferenceItem:@"increaseIndentPattern"];
	NSString *bestMatchingScope = [self bestMatchingScope:[increaseIndentPatterns allKeys] atLocation:aLocation];

	if (bestMatchingScope) {
		NSString *pattern = [increaseIndentPatterns objectForKey:bestMatchingScope];
		ViRegexp *rx = [[ViRegexp alloc] initWithString:pattern];
		NSString *checkLine = [[self textStorage] lineForLocation:aLocation];

		if ([rx matchInString:checkLine])
			return YES;
	}

	return NO;
}

- (BOOL)shouldIncreaseIndentOnceAtLocation:(NSUInteger)aLocation
{
	NSDictionary *increaseIndentPatterns = [[ViBundleStore defaultStore] preferenceItem:@"indentNextLinePattern"];
	NSString *bestMatchingScope = [self bestMatchingScope:[increaseIndentPatterns allKeys] atLocation:aLocation];

	if (bestMatchingScope) {
		NSString *pattern = [increaseIndentPatterns objectForKey:bestMatchingScope];
		ViRegexp *rx = [[ViRegexp alloc] initWithString:pattern];
		NSString *checkLine = [[self textStorage] lineForLocation:aLocation];

		if ([rx matchInString:checkLine])
			return YES;
	}

	return NO;
}

- (BOOL)shouldDecreaseIndentAtLocation:(NSUInteger)aLocation
{
	NSDictionary *decreaseIndentPatterns = [[ViBundleStore defaultStore] preferenceItem:@"decreaseIndentPattern"];
	NSString *bestMatchingScope = [self bestMatchingScope:[decreaseIndentPatterns allKeys] atLocation:aLocation];

	if (bestMatchingScope) {
		NSString *pattern = [decreaseIndentPatterns objectForKey:bestMatchingScope];
		ViRegexp *rx = [[ViRegexp alloc] initWithString:pattern];
		NSString *checkLine = [[self textStorage] lineForLocation:aLocation];

		if ([rx matchInString:checkLine])
			return YES;
	}
	
	return NO;
}

- (BOOL)shouldIgnoreIndentAtLocation:(NSUInteger)aLocation
{
	NSDictionary *unIndentPatterns = [[ViBundleStore defaultStore] preferenceItem:@"unIndentedLinePattern"];
	NSString *bestMatchingScope = [self bestMatchingScope:[unIndentPatterns allKeys] atLocation:aLocation];

	if (bestMatchingScope) {
		NSString *pattern = [unIndentPatterns objectForKey:bestMatchingScope];
		ViRegexp *rx = [[ViRegexp alloc] initWithString:pattern];
		NSString *checkLine = [[self textStorage] lineForLocation:aLocation];

		if ([rx matchInString:checkLine])
			return YES;
	}

	return NO;
}

- (NSInteger)calculatedIndentLengthAtLocation:(NSUInteger)aLocation
{
	NSDictionary *indentExpressions = [[ViBundleStore defaultStore] preferenceItem:@"indentExpression"];
	NSString *bestMatchingScope = [self bestMatchingScope:[indentExpressions allKeys] atLocation:aLocation];
	
	if (bestMatchingScope) {
		NSString *expression = [indentExpressions objectForKey:bestMatchingScope];
		DEBUG(@"running indent expression:\n%@", expression);
		NSError *error = nil;
		id result = [[NSApp delegate] eval:expression error:&error];
		if (error)
			MESSAGE(@"indent expression failed: %@", [error localizedDescription]);
		else if ([result isKindOfClass:[NSNumber class]])
			return [result integerValue];
		else
			MESSAGE(@"non-numeric result: got %@", NSStringFromClass([result class]));
	}

	return -1;
}

- (NSString *)suggestedIndentAtLocation:(NSUInteger)location forceSmartIndent:(BOOL)smartFlag
{
	BOOL smartIndent = smartFlag || [[self preference:@"smartindent" atLocation:location] integerValue];

	NSInteger calcIndent = -1;
	if (smartIndent)
		calcIndent = [self calculatedIndentLengthAtLocation:location];
	if (calcIndent >= 0) {
		DEBUG(@"calculated indent at %lu to %lu", location, calcIndent);
		return [self indentStringOfLength:calcIndent];
	}

	/* Find out indentation of first (non-blank) line before the affected range. */
	NSUInteger bol, end;
	[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:location];
	NSUInteger len = 0;
	if (bol == 0) /* First line can't be indented. */
		return 0;
	for (; bol > 0;) {
		[self getLineStart:&bol end:NULL contentsEnd:&end forLocation:bol - 1];
		if (smartIndent && [[self textStorage] isBlankLineAtLocation:bol])
			DEBUG(@"line %lu is blank", [[self textStorage] lineNumberAtLocation:bol]);
		else if (smartIndent && [self shouldIgnoreIndentAtLocation:bol])
			DEBUG(@"line %lu is ignored", [[self textStorage] lineNumberAtLocation:bol]);
		else {
			len = [self lengthOfIndentAtLocation:bol];
			DEBUG(@"indent at line %lu is %lu", [[self textStorage] lineNumberAtLocation:bol], len);
			break;
		}
	}

	NSInteger shiftWidth = [[self preference:@"shiftwidth" atLocation:location] integerValue];
	if (smartIndent && ![self shouldIgnoreIndentAtLocation:bol]) {
		if ([self shouldIncreaseIndentAtLocation:bol] ||
		    [self shouldIncreaseIndentOnceAtLocation:bol]) {
			DEBUG(@"increase indent at %lu", bol);
			len += shiftWidth;
		} else {
			/* Check if previous lines are indented by an indentNextLinePattern. */
			while (bol > 0) {
				[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:bol - 1];
				if ([self shouldIgnoreIndentAtLocation:bol]) {
					continue;
				} if ([self shouldIncreaseIndentOnceAtLocation:bol]) {
					DEBUG(@"compensating for indentNextLinePattern at line %lu",
					    [[self textStorage] lineNumberAtLocation:bol]);
					len -= shiftWidth;
				} else
					break;
			}
	
			if ([self shouldDecreaseIndentAtLocation:location]) {
				DEBUG(@"decrease indent at %lu", location);
				len -= shiftWidth;
			}
		}
	}

	return [self indentStringOfLength:len];
}

- (NSString *)suggestedIndentAtLocation:(NSUInteger)location
{
	return [self suggestedIndentAtLocation:location forceSmartIndent:NO];
}

- (id)preference:(NSString *)name forScope:(NSArray *)scopeArray
{
	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	NSDictionary *prefs = [defs dictionaryForKey:@"scopedPreferences"];
	if (prefs == nil)
		return [defs objectForKey:name];
	u_int64_t max_rank = 0;
	id scopeValue = nil;
	for (NSString *scope in [prefs allKeys]) {
		NSDictionary *scopePrefs = [prefs objectForKey:scope];
		id value = [scopePrefs objectForKey:name];
		if (value == nil)
			continue;
		u_int64_t rank = [scope matchesScopes:scopeArray];
		if (rank > max_rank) {
			max_rank = rank;
			scopeValue = value;
		}
	}

	if (scopeValue == nil)
		return [defs objectForKey:name];
	return scopeValue;
}

- (id)preference:(NSString *)name atLocation:(NSUInteger)aLocation
{
	return [self preference:name forScope:[self scopesAtLocation:aLocation]];
}

- (id)preference:(NSString *)name
{
	return [self preference:name atLocation:[self caret]];
}

- (NSUInteger)insertNewlineAtLocation:(NSUInteger)aLocation indentForward:(BOOL)indentForward
{
	NSString *leading_whitespace = [[self textStorage] leadingWhitespaceForLineAtLocation:aLocation];

	aLocation = [self removeTrailingAutoIndentForLineAtLocation:aLocation];

	NSRange smartRange;
	if ([[self layoutManager] temporaryAttribute:ViSmartPairAttributeName
				    atCharacterIndex:aLocation
				      effectiveRange:&smartRange] && smartRange.length > 1)
	{
		// assumes indentForward
		[self insertString:[NSString stringWithFormat:@"\n\n%@", leading_whitespace] atLocation:aLocation];
	} else
		[self insertString:@"\n" atLocation:aLocation];

	if ([[self preference:@"autoindent"] integerValue] == NSOnState) {
		if (indentForward)
			aLocation += 1;

		[self setCaret:aLocation];
		leading_whitespace = [self suggestedIndentAtLocation:aLocation];
		if (leading_whitespace) {
			NSRange curIndent = [[self textStorage] rangeOfLeadingWhitespaceForLineAtLocation:aLocation];
			[self replaceCharactersInRange:curIndent withString:leading_whitespace];
			NSRange autoIndentRange = NSMakeRange(curIndent.location, [leading_whitespace length]);
			[[[self layoutManager] nextRunloop] addTemporaryAttribute:ViAutoIndentAttributeName
									    value:[NSNumber numberWithInt:1]
								forCharacterRange:autoIndentRange];
			return aLocation + autoIndentRange.length;
		}
	}

	if (indentForward)
		return aLocation + 1;
	else
		return aLocation;
}

- (NSRange)changeIndentation:(int)delta inRange:(NSRange)aRange updateCaret:(NSUInteger *)updatedCaret
{
	NSInteger shiftWidth = [[self preference:@"shiftwidth" atLocation:aRange.location] integerValue];
	if (shiftWidth == 0)
		shiftWidth = 8;
	NSUInteger bol;
	[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:aRange.location];

	NSRange delta_offset = NSMakeRange(0, 0);
	BOOL has_delta_offset = NO;

	while (bol < NSMaxRange(aRange)) {
		NSString *indent = [[self textStorage] leadingWhitespaceForLineAtLocation:bol];
		NSUInteger n = [self lengthOfIndentString:indent];
		if (n % shiftWidth != 0 && !updatedCaret) {
			/* XXX: updatedCaret is nil when called from ctrl-t / ctrl-d */
			if (delta < 0)
				n += shiftWidth - (n % shiftWidth);
			else
				n -= n % shiftWidth;
		}
		NSString *newIndent = [self indentStringOfLength:n + delta * shiftWidth];
		if ([[self textStorage] isBlankLineAtLocation:bol] && updatedCaret)
			/* XXX: should not indent empty lines when using the < or > operators. */
			newIndent = indent;

		NSRange indentRange = NSMakeRange(bol, [indent length]);
		[self replaceRange:indentRange withString:newIndent];

		aRange.length += [newIndent length] - [indent length];
		if (!has_delta_offset) {
			has_delta_offset = YES;
			delta_offset.location = [newIndent length] - [indent length];
		}
		delta_offset.length += [newIndent length] - [indent length];
		if (updatedCaret && *updatedCaret >= indentRange.location) {
			NSInteger d = [newIndent length] - [indent length];
			*updatedCaret = IMAX((NSInteger)*updatedCaret + d, bol);
		}

		// get next line
		[self getLineStart:NULL end:&bol contentsEnd:NULL forLocation:bol];
		if (bol == NSNotFound)
			break;
	}

	return delta_offset;
}

- (NSRange)changeIndentation:(int)delta inRange:(NSRange)aRange
{
	return [self changeIndentation:delta inRange:aRange updateCaret:nil];
}

- (BOOL)increase_indent:(ViCommand *)command
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	NSRange n = [self changeIndentation:+1 inRange:NSMakeRange(bol, IMAX(eol - bol, 1))];
	final_location = start_location + n.location;
	return YES;
}

- (BOOL)decrease_indent:(ViCommand *)command
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	NSRange n = [self changeIndentation:-1 inRange:NSMakeRange(bol, eol - bol)];
	final_location = start_location + n.location;
	return YES;
}

#pragma mark -
#pragma mark Undo support

- (IBAction)undo:(id)sender
{
	[self setNormalMode];
	[[self textStorage] beginEditing];
	[undoManager undo];
	[[self textStorage] endEditing];
	[self setCaret:final_location];
}

- (IBAction)redo:(id)sender
{
	[self setNormalMode];
	[[self textStorage] beginEditing];
	[undoManager redo];
	[[self textStorage] endEditing];
	[self setCaret:final_location];
}

- (void)endUndoGroup
{
	DEBUG(@"Ending undo-group: %@", hasUndoGroup ? @"YES" : @"NO");
	if (hasUndoGroup) {
		[undoManager endUndoGrouping];
		hasUndoGroup = NO;
	}
}

- (void)beginUndoGroup
{
	if (!hasUndoGroup) {
		[undoManager beginUndoGrouping];
		hasUndoGroup = YES;
	}
}

- (void)undoReplaceOfString:(NSString *)aString inRange:(NSRange)aRange
{
	DEBUG(@"undoing replacement of string %@ in range %@", aString, NSStringFromRange(aRange));
	[self replaceCharactersInRange:aRange withString:aString undoGroup:NO];
	final_location = aRange.location;

	NSUInteger bol, eol, end;
	[self getLineStart:&bol end:&end contentsEnd:&eol forLocation:final_location];
	if (final_location >= eol && final_location > bol)
		final_location = eol - 1;
}

- (void)recordReplacementOfRange:(NSRange)aRange withLength:(NSUInteger)aLength
{
	NSRange newRange = NSMakeRange(aRange.location, aLength);
	NSString *s = [[[self textStorage] string] substringWithRange:aRange];
	DEBUG(@"pushing replacement of range %@ (string [%@]) with %@ onto undo stack",
	    NSStringFromRange(aRange), s, NSStringFromRange(newRange));
	[[undoManager prepareWithInvocationTarget:self] undoReplaceOfString:s inRange:newRange];
	[undoManager setActionName:@"replace text"];
}

#pragma mark -
#pragma mark Register

- (void)yankToRegister:(unichar)regName
                 range:(NSRange)yankRange
{
	NSString *content = [[[self textStorage] string] substringWithRange:yankRange];
	[[ViRegisterManager sharedManager] setContent:content ofRegister:regName];
	[self setMark:'[' atLocation:yankRange.location];
	[self setMark:']' atLocation:IMAX(yankRange.location, NSMaxRange(yankRange) - 1)];
}

- (void)cutToRegister:(unichar)regName
                range:(NSRange)cutRange
{
	[self yankToRegister:regName range:cutRange];
	[self deleteRange:cutRange undoGroup:YES];
	[self setMark:']' atLocation:cutRange.location];
}

#pragma mark -
#pragma mark Convenience methods

- (void)gotoColumn:(NSUInteger)column fromLocation:(NSUInteger)aLocation
{
	end_location = [[self textStorage] locationForColumn:column
	                                        fromLocation:aLocation
	                                           acceptEOL:(mode == ViInsertMode)];
	final_location = end_location;
}

- (BOOL)gotoLine:(NSUInteger)line column:(NSUInteger)column
{
	NSInteger bol = [[self textStorage] locationForStartOfLine:line];
	if (bol == -1)
		return NO;

	[self gotoColumn:column fromLocation:bol];
	[self setCaret:final_location];
	[self scrollRangeToVisible:NSMakeRange(final_location, 0)];

	return YES;
}

- (BOOL)gotoLine:(NSUInteger)line
{
	return [self gotoLine:line column:1];
}

#pragma mark -
#pragma mark Searching

- (BOOL)findPattern:(NSString *)pattern options:(unsigned)find_options
{
	unsigned rx_options = ONIG_OPTION_NOTBOL | ONIG_OPTION_NOTEOL;
	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	if ([defs integerForKey:@"ignorecase"] == NSOnState) {
		if ([defs integerForKey:@"smartcase"] == NSOffState ||
		    [pattern rangeOfCharacterFromSet:[NSCharacterSet uppercaseLetterCharacterSet]].location == NSNotFound)
			rx_options |= ONIG_OPTION_IGNORECASE;
	}

	ViRegexp *rx = nil;

	/* compile the pattern regexp */
	@try
	{
		rx = [[ViRegexp alloc] initWithString:pattern
					      options:rx_options];
	}
	@catch(NSException *exception)
	{
		INFO(@"***** FAILED TO COMPILE REGEXP ***** [%@], exception = [%@]", pattern, exception);
		MESSAGE(@"Invalid search pattern: %@", exception);
		return NO;
	}

	NSArray *foundMatches = [rx allMatchesInString:[[self textStorage] string]
					       options:rx_options];

	if ([foundMatches count] == 0) {
		MESSAGE(@"Pattern not found");
	} else {
		[self pushLocationOnJumpList:start_location];

		ViRegexpMatch *match, *nextMatch = nil;
		for (match in foundMatches) {
			NSRange r = [match rangeOfMatchedString];
			if (find_options == 0) {
				if (nextMatch == nil && r.location > start_location) {
					nextMatch = match;
					break;
				}
			} else if (r.location < start_location) {
				nextMatch = match;
			}
		}

		if (nextMatch == nil) {
			if (find_options == 0)
				nextMatch = [foundMatches objectAtIndex:0];
			else
				nextMatch = [foundMatches lastObject];

			MESSAGE(@"Search wrapped");
		}

		if (nextMatch) {
			NSRange r = [nextMatch rangeOfMatchedString];
			[self scrollRangeToVisible:r];
			final_location = end_location = r.location;
			[self setCaret:final_location];
			[[self nextRunloop] showFindIndicatorForRange:[nextMatch rangeOfMatchedString]];
		}

		return YES;
	}

	return NO;
}

- (void)find_forward_callback:(NSString *)pattern contextInfo:(void *)contextInfo
{
	keyManager.parser.last_search_pattern = pattern;
	keyManager.parser.last_search_options = 0;
	[[ViRegisterManager sharedManager] setContent:pattern ofRegister:'/'];
	if ([self findPattern:pattern options:0])
		[self setCaret:final_location];
}

- (void)find_backward_callback:(NSString *)pattern contextInfo:(void *)contextInfo
{
	keyManager.parser.last_search_pattern = pattern;
	keyManager.parser.last_search_options = ViSearchOptionBackwards;
	[[ViRegisterManager sharedManager] setContent:pattern ofRegister:'/'];
	if ([self findPattern:pattern options:ViSearchOptionBackwards])
		[self setCaret:final_location];
}

/* syntax: /regexp */
- (BOOL)find:(ViCommand *)command
{
	[[document environment] getExCommandWithDelegate:self
						       selector:@selector(find_forward_callback:contextInfo:)
							 prompt:@"/"
						    contextInfo:command];
	// FIXME: this won't work as a motion command!
	// d/pattern will not work!
	return YES;
}

/* syntax: ?regexp */
- (BOOL)find_backwards:(ViCommand *)command
{
	[[document environment] getExCommandWithDelegate:self
						       selector:@selector(find_backward_callback:contextInfo:)
							 prompt:@"?"
						    contextInfo:command];
	// FIXME: this won't work as a motion command!
	// d?pattern will not work!
	return YES;
}

/* syntax: n */
- (BOOL)repeat_find:(ViCommand *)command
{
	NSString *pattern = keyManager.parser.last_search_pattern;
	if (pattern == nil) {
		MESSAGE(@"No previous search pattern");
		return NO;
	}

	return [self findPattern:pattern options:keyManager.parser.last_search_options];
}

/* syntax: N */
- (BOOL)repeat_find_backward:(ViCommand *)command
{
	NSString *pattern = keyManager.parser.last_search_pattern;
	if (pattern == nil) {
		MESSAGE(@"No previous search pattern");
		return NO;
	}

	int options = keyManager.parser.last_search_options;
	if (options & ViSearchOptionBackwards)
		options &= ~ViSearchOptionBackwards;
	else
		options |= ViSearchOptionBackwards;
	return [self findPattern:pattern options:options];
}

#pragma mark -
#pragma mark Caret and selection handling

- (void)scrollToCaret
{
	NSScrollView *scrollView = [self enclosingScrollView];
	NSClipView *clipView = [scrollView contentView];
	NSLayoutManager *layoutManager = [self layoutManager];
        NSRect visibleRect = [clipView bounds];
	NSUInteger glyphIndex = [layoutManager glyphIndexForCharacterAtIndex:[self caret]];
	NSRect rect = [layoutManager boundingRectForGlyphRange:NSMakeRange(glyphIndex, 0)
	                                       inTextContainer:[self textContainer]];

	rect.size.width = 20;

	NSPoint topPoint;
	CGFloat topY = visibleRect.origin.y;
	CGFloat topX = visibleRect.origin.x;

	if (NSMinY(rect) < NSMinY(visibleRect))
		topY = NSMinY(rect);
	else if (NSMaxY(rect) > NSMaxY(visibleRect))
		topY = NSMaxY(rect) - NSHeight(visibleRect);

	CGFloat jumpX = 20*rect.size.width;

	if (NSMinX(rect) < NSMinX(visibleRect))
		topX = NSMinX(rect) > jumpX ? NSMinX(rect) - jumpX : 0;
	else if (NSMaxX(rect) > NSMaxX(visibleRect))
		topX = NSMaxX(rect) - NSWidth(visibleRect) + jumpX;

	if (topX < jumpX)
		topX = 0;

	topPoint = NSMakePoint(topX, topY);

	if (topPoint.x != visibleRect.origin.x || topPoint.y != visibleRect.origin.y) {
		[clipView scrollToPoint:topPoint];
		[scrollView reflectScrolledClipView:clipView];
	}
}

- (void)setCaret:(NSUInteger)location
{
	NSInteger length = [[self textStorage] length];
	if (mode != ViInsertMode)
		length--;
	if (location > length)
		location = IMAX(0, length);
	caret = location;
	if (mode != ViVisualMode)
		[self setSelectedRange:NSMakeRange(location, 0)];
	if (!replayingInput)
		[self updateCaret];
}

- (NSUInteger)caret
{
	return caret;
}

- (NSRange)selectionRangeForProposedRange:(NSRange)proposedSelRange
                              granularity:(NSSelectionGranularity)granularity
{
	if (proposedSelRange.length == 0 && granularity == NSSelectByCharacter) {
		NSUInteger bol, eol, end;
		[self getLineStart:&bol end:&end contentsEnd:&eol forLocation:proposedSelRange.location];
		if (proposedSelRange.location == eol)
			proposedSelRange.location = IMAX(bol, eol - 1);
		return proposedSelRange;
	}
	visual_line_mode = (granularity == NSSelectByParagraph);
	return [super selectionRangeForProposedRange:proposedSelRange granularity:granularity];
}

- (void)setSelectedRanges:(NSArray *)ranges
                 affinity:(NSSelectionAffinity)affinity
           stillSelecting:(BOOL)stillSelectingFlag
{
	if (showingContextMenu)
		return;

	[super setSelectedRanges:ranges affinity:affinity stillSelecting:stillSelectingFlag];

	NSRange firstRange = [[ranges objectAtIndex:0] rangeValue];
	NSRange lastRange = [[ranges lastObject] rangeValue];

	/*DEBUG(@"still selecting = %s, firstRange = %@, lastRange = %@, mode = %i, visual_start = %lu",
	    stillSelectingFlag ? "YES" : "NO",
	    NSStringFromRange(firstRange),
	    NSStringFromRange(lastRange),
	    mode,
	    visual_start_location);*/

	if ([ranges count] > 1 || firstRange.length > 0) {
		if (mode != ViVisualMode) {
			[self setVisualMode];
			[self setCaret:firstRange.location];
			visual_start_location = firstRange.location;
		} else if (stillSelectingFlag) {
			if (visual_start_location == firstRange.location)
				[self setCaret:IMAX(lastRange.location, NSMaxRange(lastRange) - 1)];
			else
				[self setCaret:firstRange.location];
		}
		[self updateStatus];
	} else if (stillSelectingFlag) {
		[self setNormalMode];
		if (firstRange.location != [self caret])
			[self setCaret:firstRange.location];
		[self updateStatus];
	}
}

- (void)setVisualSelection
{
	NSUInteger l1 = visual_start_location, l2 = [self caret];
	if (l2 < l1)
	{	/* swap if end < start */
		l2 = l1;
		l1 = end_location;
	}

	if (visual_line_mode)
	{
		NSUInteger bol, end;
		[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:l1];
		[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:l2];
		l1 = bol;
		l2 = end;
	}
	else
		l2++;

	[self setMark:'<' atLocation:l1];
	[self setMark:'>' atLocation:IMAX(l1, l2 - 1)];

	NSRange sel = NSMakeRange(l1, l2 - l1);
	[self setSelectedRange:sel];
}

#pragma mark -

- (void)setNormalMode
{
	DEBUG(@"setting normal mode, caret = %u, final_location = %u, length = %u",
	    caret, final_location, [[self textStorage] length]);
	mode = ViNormalMode;
	[self setMark:']' atLocation:end_location];
	[self endUndoGroup];
}

- (void)resetSelection
{
	DEBUG(@"resetting selection, caret = %u", [self caret]);
	[self setSelectedRange:NSMakeRange([self caret], 0)];
}

- (void)setVisualMode
{
	mode = ViVisualMode;
}

- (void)setInsertMode:(ViCommand *)command
{
	DEBUG(@"entering insert mode at location %u (final location is %u), length is %u",
		end_location, final_location, [[self textStorage] length]);
	mode = ViInsertMode;

	[self setMark:'[' atLocation:end_location];

	/*
	 * Remember the command that entered insert mode. When leaving insert mode,
	 * we update this command with the inserted text (or keys, actually). This
	 * is used for repeating the insertion with the dot command.
	 */
	lastEditCommand = command;

	if (command) {
		if (command.text) {
			replayingInput = YES;
			[self setCaret:end_location];
			int count = IMAX(1, command.count);
			int i;
			for (i = 0; i < count; i++)
				[keyManager handleKeys:command.text
					       inScope:[self scopesAtLocation:end_location]];
			[self normal_mode:command];
			replayingInput = NO;
		}
	}
}

#pragma mark -
#pragma mark Input handling and command evaluation

- (BOOL)handleSmartPair:(NSString *)characters
{
	if ([[self preference:@"smartpair"] integerValue] == 0)
		return NO;

	BOOL foundSmartTypingPair = NO;

	ViTextStorage *ts = [self textStorage];
	NSString *string = [ts string];
	NSUInteger length = [ts length];

	DEBUG(@"testing %@ for smart pair", characters);

	NSArray *smartTypingPairs = [self smartTypingPairsAtLocation:IMIN(start_location, length - 1)];
	NSArray *pair;
	for (pair in smartTypingPairs) {
		NSString *pair0 = [pair objectAtIndex:0];
		NSString *pair1 = [pair objectAtIndex:1];

		DEBUG(@"got pairs %@ and %@ at %lu < %lu", pair0, pair1, start_location, length);

		/*
		 * Check if we're inserting the end character of a smart typing pair.
		 * If so, just overwrite the end character.
		 * Note: start and end characters might be the same (eg, "").
		 */
		if (start_location < length &&
		    [characters isEqualToString:pair1] &&
		    [[string substringWithRange:NSMakeRange(start_location, 1)]
		     isEqualToString:pair1]) {
			if ([[self layoutManager] temporaryAttribute:ViSmartPairAttributeName
						    atCharacterIndex:start_location
						      effectiveRange:NULL]) {
				foundSmartTypingPair = YES;
				final_location = start_location + [pair1 length];
			}
			break;
		}
		// check for the start character of a smart typing pair
		else if ([characters isEqualToString:pair0]) {
			/*
			 * Only use if next character is not alphanumeric.
			 * FIXME: ...and next character is not any start character of a smart pair?
			 */
			if (start_location >= length ||
			    ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:
					    [string characterAtIndex:start_location]])
			{
				foundSmartTypingPair = YES;
				[self insertString:[NSString stringWithFormat:@"%@%@",
					pair0,
					pair1] atLocation:start_location];

				NSRange r = NSMakeRange(start_location, [pair0 length] + [pair1 length]);
				DEBUG(@"adding smart pair attr to %@", NSStringFromRange(r));
				[[[self layoutManager] nextRunloop] addTemporaryAttribute:ViSmartPairAttributeName
				                                                    value:characters
				                                        forCharacterRange:r];

				final_location = start_location + [pair1 length];
				break;
			}
		}
	}

	return foundSmartTypingPair;
}

/* Input a character from the user (in insert mode). Handle smart typing pairs.
 * FIXME: assumes smart typing pairs are single characters.
 */
- (void)handle_input:(unichar)character
{
	DEBUG(@"insert character %C at %i", character, start_location);

	// If there is a selected snippet range, remove it first.
	ViSnippet *snippet = document.snippet;
	NSRange sel = snippet.selectedRange;
	if (sel.length > 0) {
		[self deleteRange:sel];
		start_location = modify_start_location;
	}

	NSString *s = [NSString stringWithFormat:@"%C", character];
	if (![self handleSmartPair:s]) {
		DEBUG(@"%s", "no smart typing pairs triggered");
		[self insertString:s
			atLocation:start_location];
		final_location = modify_start_location + 1;
	}
}

- (BOOL)literal_next:(ViCommand *)command
{
	[self handle_input:command.argument];
	return YES;
}

- (BOOL)input_character:(ViCommand *)command
{
	for (NSNumber *n in command.mapping.keySequence) {
		NSInteger keyCode = [n integerValue];

		if ((keyCode & 0xFFFF0000) != 0) {
			MESSAGE(@"Can't insert key equivalent: %@.",
			    [NSString stringWithKeyCode:keyCode]);
			return NO;
		}

		if (keyCode < 0x20) {
			MESSAGE(@"Illegal character: %@; quote to enter",
			    [NSString stringWithKeyCode:keyCode]);
			return NO;
		}

		[self handle_input:keyCode];
		start_location = final_location;
	}

	return YES;
}

- (BOOL)input_newline:(ViCommand *)command
{
	final_location = [self insertNewlineAtLocation:start_location
					 indentForward:YES];
	return YES;
}

- (BOOL)input_tab:(ViCommand *)command
{
	// check if we're inside a snippet
	ViSnippet *snippet = document.snippet;
	if (snippet) {
		[[self layoutManager] invalidateDisplayForCharacterRange:snippet.selectedRange];
		if ([snippet advance]) {
			final_location = snippet.caret;
			[[self layoutManager] invalidateDisplayForCharacterRange:snippet.selectedRange];
			return YES;
		} else
			[self cancelSnippet:snippet];
	}

	/* Check for a tab trigger before the caret.
	 */
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	NSString *prefix = [[[self textStorage] string] substringWithRange:NSMakeRange(bol, start_location - bol)];
	if ([prefix length] > 0) {
		NSArray *scopes = [self scopesAtLocation:eol];
		NSUInteger triggerLength;
		NSArray *matches = [[ViBundleStore defaultStore] itemsWithTabTrigger:prefix
									matchingScopes:scopes
										inMode:mode
									 matchedLength:&triggerLength];
		if ([matches count] > 0) {
			snippetMatchRange = NSMakeRange(start_location - triggerLength, triggerLength);
			[self performBundleItems:matches];
			return NO;
		}
	}

	// otherwise just insert a tab
	[self insertString:@"\t" atLocation:start_location];
	final_location = start_location + 1;

	return YES;
}

- (NSArray *)smartTypingPairsAtLocation:(NSUInteger)aLocation
{
	NSDictionary *smartTypingPairs = [[ViBundleStore defaultStore] preferenceItem:@"smartTypingPairs"];
	NSString *bestMatchingScope = [self bestMatchingScope:[smartTypingPairs allKeys] atLocation:aLocation];

	if (bestMatchingScope) {
		DEBUG(@"found smart typing pair scope selector [%@] at location %i", bestMatchingScope, aLocation);
		return [smartTypingPairs objectForKey:bestMatchingScope];
	}

	return nil;
}

- (BOOL)input_backspace:(ViCommand *)command
{
	// If there is a selected snippet range, remove it first.
	ViSnippet *snippet = document.snippet;
	NSRange sel = snippet.selectedRange;
	if (sel.length > 0) {
		[self deleteRange:sel];
		start_location = modify_start_location;
		return YES;
	}

	if (start_location == 0) {
		MESSAGE(@"Already at the beginning of the document");
		return YES;
	}

	/* check if we're deleting the first character in a smart pair */
	NSRange r;
	if ([[self layoutManager] temporaryAttribute:ViSmartPairAttributeName
				    atCharacterIndex:start_location
				      effectiveRange:&r]) {
		DEBUG(@"found smart pair in range %@", NSStringFromRange(r));
		if (r.location == start_location - 1 && r.length == 2) {
			[self deleteRange:NSMakeRange(start_location - 1, 2)];
			final_location = modify_start_location;
			return YES;
		}
	}

	/* else a regular character, just delete it */
	[self deleteRange:NSMakeRange(start_location - 1, 1)];
	final_location = modify_start_location;

	return YES;
}

- (BOOL)input_forward_delete:(ViCommand *)command
{
	/* FIXME: should handle smart typing pairs here!
	 */
	[self deleteRange:NSMakeRange(start_location, 1)];
	final_location = start_location;
	return YES;
}

- (NSUInteger)removeTrailingAutoIndentForLineAtLocation:(NSUInteger)aLocation
{
	DEBUG(@"checking for auto-indent at %lu", aLocation);
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol forLocation:aLocation];
	NSRange r;
	if ([[self layoutManager] temporaryAttribute:ViAutoIndentAttributeName
				    atCharacterIndex:bol
				      effectiveRange:&r]) {
		DEBUG(@"got auto-indent whitespace in range %@ for line between %lu and %lu", NSStringFromRange(r), bol, eol);
		if (r.location == bol && NSMaxRange(r) == eol) {
			[self replaceCharactersInRange:NSMakeRange(bol, eol - bol) withString:@""];
			return bol;

		}
	}

	return aLocation;
}

- (BOOL)normal_mode:(ViCommand *)command
{
	if (mode == ViInsertMode) {
		if (!replayingInput) {
			/*
			 * Remember the typed keys so we can repeat it
			 * with the dot command.
			 */
			[lastEditCommand setText:inputKeys];

			/*
			 * A count given to the command that started insert
			 * mode (i, I, a or A) means we should multiply the
			 * inserted text.
			 */
			DEBUG(@"last edit command is %@, got %lu input keys",
			    lastEditCommand, [inputKeys count]);
			int count = IMAX(1, lastEditCommand.count);
			if (count > 1) {
				replayingInput = YES;
				for (int i = 1; i < count; i++)
					[keyManager handleKeys:inputKeys
						       inScope:[self scopesAtLocation:[self caret]]];
				replayingInput = NO;
			}
		}

		inputKeys = [NSMutableArray array];
		start_location = end_location = [self caret];
		[self move_left:nil];
	}

	final_location = [self removeTrailingAutoIndentForLineAtLocation:final_location];

	[self setNormalMode];
	[self setCaret:final_location];
	[self resetSelection];

	return YES;
}

- (void)updateStatus
{
	if ([self isFieldEditor])
		return;

	const char *modestr = "";
	if (mode == ViInsertMode) {
		if (document.snippet)
			modestr = "--SNIPPET--";
		else
			modestr = "--INSERT--";
	} else if (mode == ViVisualMode) {
		if (visual_line_mode)
			modestr = "--VISUAL LINE--";
		else
			modestr = "--VISUAL--";
	}
	MESSAGE([NSString stringWithFormat:@"%lu,%lu   %s",
	    (unsigned long)[self currentLine],
	    (unsigned long)[self currentColumn],
	    modestr]);
}

- (id)targetForCommand:(ViCommand *)command
{
	NSView *view = self;

	do {
		if ([view respondsToSelector:command.action])
			return view;
	} while ((view = [view superview]) != nil);

	if ([[self window] respondsToSelector:command.action])
		return [self window];

	if ([[[self window] windowController] respondsToSelector:command.action])
		return [[self window] windowController];

	if ([[self delegate] respondsToSelector:command.action])
		return [self delegate];

	if ([document respondsToSelector:command.action])
		return document;

	return nil;
}

- (BOOL)keyManager:(ViKeyManager *)keyManager
   evaluateCommand:(ViCommand *)command
{
	if (mode != ViInsertMode)
		[self endUndoGroup];

	id target = [self targetForCommand:command];
	if (target == nil) {
		MESSAGE(@"Command %@ not implemented.",
		    command.mapping.keyString);
		return NO;
	}

	id motion_target = nil;
	if (command.motion) {
		motion_target = [self targetForCommand:command.motion];
		if (motion_target == nil) {
			MESSAGE(@"Motion command %@ not implemented.",
			    command.motion.mapping.keyString);
			return NO;
		}
	}

	/* Default start- and end-location is the current location. */
	start_location = [self caret];
	end_location = start_location;
	final_location = start_location;
	DEBUG(@"start_location = %u", start_location);

	/* Set or reset the saved column for up/down movement. */
	if (command.action == @selector(move_down:) ||
	    command.action == @selector(move_up:) ||
	    command.action == @selector(scroll_down_by_line:) ||
	    command.action == @selector(scroll_up_by_line:) ||
	    command.motion.action == @selector(move_down:) ||
	    command.motion.action == @selector(move_up:) ||
	    command.motion.action == @selector(scroll_down_by_line:) ||
	    command.motion.action == @selector(scroll_up_by_line:)) {
		if (saved_column < 0)
			saved_column = [self currentColumn];
	} else
		saved_column = -1;

	if (command.action != @selector(vi_undo:) && !command.fromDot)
		undo_direction = 0;

	if (command.motion) {
		/* The command has an associated motion component.
		 * Run the motion command and record the start and end locations.
		 */
		DEBUG(@"perform motion command %@", command.motion);
		if (![motion_target performSelector:command.motion.action
					 withObject:command.motion])
			/* the command failed */
			return NO;
	}

	/* Find out the affected range for this command. */
	NSUInteger l1, l2;
	if (mode == ViVisualMode) {
		NSRange sel = [self selectedRange];
		l1 = sel.location;
		l2 = NSMaxRange(sel);
	} else {
		l1 = start_location, l2 = end_location;
		if (l2 < l1) {
			/* swap if end < start */
			l2 = l1;
			l1 = end_location;
		}
	}
	DEBUG(@"affected locations: %u -> %u (%u chars), caret = %u, length = %u",
	    l1, l2, l2 - l1, [self caret], [[self textStorage] length]);

	if (command.isLineMode && !command.isMotion && mode != ViVisualMode) {
		/*
		 * If this command is line oriented, extend the
		 * affectedRange to whole lines. However, don't
		 * do this for Visual-Line mode, this is done in
		 * setVisualSelection.
		 */
		NSUInteger bol, end, eol;
		[self getLineStart:&bol end:&end contentsEnd:&eol forLocation:l1];

		if (command.motion == nil) {
			/*
			 * This is a "doubled" command (like dd or yy).
			 * A count affects that number of whole lines.
			 */
			int line_count = command.count;
			while (--line_count > 0) {
				l2 = end;
				[self getLineStart:NULL
					       end:&end
				       contentsEnd:NULL
				       forLocation:l2];
			}
		} else
			[self getLineStart:NULL
				       end:&end
			       contentsEnd:NULL
			       forLocation:l2];

		l1 = bol;
		l2 = end;
		DEBUG(@"after line mode correction: %u -> %u (%u chars)",
		    l1, l2, l2 - l1);
	}
	affectedRange = NSMakeRange(l1, l2 - l1);

	BOOL leaveVisualMode = NO;
	if (mode == ViVisualMode && !command.isMotion &&
	    command.action != @selector(visual:) &&
	    command.action != @selector(visual_line:)) {
		/* If in visual mode, edit commands leave visual mode. */
		leaveVisualMode = YES;
	}

	DEBUG(@"perform command %@", command);
	DEBUG(@"start_location = %u", start_location);
	BOOL ok = (NSUInteger)[target performSelector:command.action withObject:command];
	if (ok && command.isLineMode && !command.isMotion &&
	    command.action != @selector(yank:) &&
	    command.action != @selector(shift_right:) &&
	    command.action != @selector(shift_left:) &&
	    command.action != @selector(subst_lines:))
	{
		/* For line mode operations, we always end up at the beginning of the line. */
		/* ...well, except for yy :-) */
		/* ...and > */
		/* ...and < */
		// FIXME: this is not a generic case!
		final_location = [[self textStorage] firstNonBlankAtLocation:final_location];
	}

	if (leaveVisualMode && mode == ViVisualMode) {
		/* If the command didn't itself leave visual mode, do it now. */
		[self setNormalMode];
		[self resetSelection];
	}

	DEBUG(@"final_location is %u", final_location);
	if (final_location != NSNotFound)
		[self setCaret:final_location];
	if (mode == ViVisualMode)
		[self setVisualSelection];

	if (!replayingInput)
		[self scrollToCaret];

	if (ok)
		[self updateStatus];

	return ok;
}

- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange
{
	NSString *string;

	if ([aString isMemberOfClass:[NSAttributedString class]])
		string = [aString string];
	else
		string = aString;

	DEBUG(@"string = [%@], len %i, replacementRange = %@",
	    string, [string length], NSStringFromRange(replacementRange));

	if ([self hasMarkedText])
		[self unmarkText];

	/*
	 * For some weird reason, ctrl-alt-a wants to insert the character 0x01.
	 * We don't want that, but rather have the opportunity to map it.
	 * If you want a real 0x01 (ctrl-a) in the text, type <ctrl-v><ctrl-a>.
	 */
	if ([string length] > 0) {
		unichar ch = [string characterAtIndex:0];
		if (ch < 0x20)
			return;
	}

	if (replacementRange.location == NSNotFound) {
		NSInteger i;
		for (i = 0; i < [string length]; i++)
			[keyManager handleKey:[string characterAtIndex:i]
				      inScope:[self scopesAtLocation:[self caret]]];
		insertedKey = YES;
	}
}

- (void)doCommandBySelector:(SEL)aSelector
{
	DEBUG(@"selector = %@ (ignored)", NSStringFromSelector(aSelector));
}

- (void)keyManager:(ViKeyManager *)aKeyManager
      presentError:(NSError *)error
{
	MESSAGE(@"%@", [error localizedDescription]);
}

- (void)keyManager:(ViKeyManager *)aKeyManager
  partialKeyString:(NSString *)keyString
{
	MESSAGE(@"%@", keyString);
}

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
	DEBUG(@"got key equivalent event %p = %@", theEvent, theEvent);

	if ([[self window] firstResponder] != self)
		return NO;

	return [keyManager performKeyEquivalent:theEvent
					inScope:[self scopesAtLocation:[self caret]]];
}

- (void)keyDown:(NSEvent *)theEvent
{
	DEBUG(@"got keyDown event: %p = %@", theEvent, theEvent);

	handlingKey = YES;
	[super keyDown:theEvent];
	handlingKey = NO;
	DEBUG(@"done interpreting key events, inserted key = %s",
	    insertedKey ? "YES" : "NO");

	if (!insertedKey && ![self hasMarkedText]) {
		DEBUG(@"decoding event %@", theEvent);
		[keyManager keyDown:theEvent inScope:[self scopesAtLocation:[self caret]]];
	}
	insertedKey = NO;
}

- (BOOL)keyManager:(ViKeyManager *)aKeyManager
    shouldParseKey:(NSInteger)keyCode
{
	if (mode == ViInsertMode && !replayingInput && keyCode != 0x1B) {
		/* Add the key to the input replay queue. */
		[inputKeys addObject:[NSNumber numberWithInteger:keyCode]];
	}

//	[proxy emit:@"keyDown" with:self, keyCode, nil];

	/*
	 * Find and perform bundle commands. Show a menu with commands
	 * if multiple matches found.
	 * FIXME: should this be part of the key replay queue?
	 */
	if (!keyManager.parser.partial && ![self isFieldEditor]) {
		NSArray *scopes = [self scopesAtLocation:[self caret]];
		NSArray *matches = [[ViBundleStore defaultStore] itemsWithKeyCode:keyCode
								     matchingScopes:scopes
									     inMode:mode];
		if ([matches count] > 0) {
			[self performBundleItems:matches];
			return NO; /* We already handled the key */
		}
	}

	if (!keyManager.parser.partial && ![self isFieldEditor]) {
		if (mode == ViVisualMode)
			[keyManager.parser setVisualMap];
		else if (mode == ViInsertMode)
			[keyManager.parser setInsertMap];
	}

	return YES;
}

- (void)swipeWithEvent:(NSEvent *)event
{
	BOOL rc = NO, keep_message = NO;

	DEBUG(@"got swipe event %@", event);

	if ([event deltaX] != 0 && mode == ViInsertMode) {
		MESSAGE(@"Swipe event interrupted text insert mode.");
		[self normal_mode:lastEditCommand];
		keep_message = YES;
	}

	if ([event deltaX] > 0)
		rc = [self jumplist_backward:nil];
	else if ([event deltaX] < 0)
		rc = [self jumplist_forward:nil];

	if (rc == YES && !keep_message)
		MESSAGE(@""); // erase any previous message
}

/* Takes a string of characters and creates a macro of it.
 * Then feeds it into the key manager.
 */
- (void)input:(NSString *)inputString
{
	NSArray *keys = [inputString keyCodes];
	if (keys == nil) {
		INFO(@"invalid key sequence: %@", inputString);
		return;
	}
	[keyManager runAsMacro:inputString];
}

#pragma mark -

/* This is stolen from Smultron.
 */
- (void)drawPageGuideInRect:(NSRect)rect
{
	if (pageGuideX > 0) {
		NSRect bounds = [self bounds];
		if ([self needsToDrawRect:NSMakeRect(pageGuideX, 0, 1, bounds.size.height)] == YES) {
			// So that it doesn't draw the line if only e.g. the cursor updates
			[[[self insertionPointColor] colorWithAlphaComponent:0.3] set];
			[NSBezierPath strokeRect:NSMakeRect(pageGuideX, 0, 0, bounds.size.height)];
		}
	}
}

- (void)setPageGuide:(NSInteger)pageGuideValue
{
	if (pageGuideValue == 0)
		pageGuideX = 0;
	else {
		NSDictionary *sizeAttribute = [[NSDictionary alloc] initWithObjectsAndKeys:[ViThemeStore font], NSFontAttributeName, nil];
		CGFloat sizeOfCharacter = [@" " sizeWithAttributes:sizeAttribute].width;
		pageGuideX = (sizeOfCharacter * (pageGuideValue + 1)) - 1.5;
		// -1.5 to put it between the two characters and draw only on one pixel and
		// not two (as the system draws it in a special way), and that's also why the
		// width above is set to zero
	}
	[self display];
}

- (void)setWrapping:(BOOL)enabled
{
	const float LargeNumberForText = 1.0e7;

	NSScrollView *scrollView = [self enclosingScrollView];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:!enabled];
	[scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	NSTextContainer *textContainer = [self textContainer];
	if (enabled)
		[textContainer setContainerSize:NSMakeSize([scrollView contentSize].width, LargeNumberForText)];
	else
		[textContainer setContainerSize:NSMakeSize(LargeNumberForText, LargeNumberForText)];
	[textContainer setWidthTracksTextView:enabled];
	[textContainer setHeightTracksTextView:NO];

	if (enabled)
		[self setMaxSize:NSMakeSize([scrollView contentSize].width, LargeNumberForText)];
	else
		[self setMaxSize:NSMakeSize(LargeNumberForText, LargeNumberForText)];
	[self setHorizontallyResizable:!enabled];
	[self setVerticallyResizable:YES];
	[self setAutoresizingMask:(enabled ? NSViewWidthSizable : NSViewNotSizable)];
}

- (void)setTheme:(ViTheme *)aTheme
{
	caretColor = [aTheme caretColor];
	[self setBackgroundColor:[aTheme backgroundColor]];
	[[self enclosingScrollView] setBackgroundColor:[aTheme backgroundColor]];
	[self setInsertionPointColor:[aTheme caretColor]];
	[self setSelectedTextAttributes:[NSDictionary dictionaryWithObject:[aTheme selectionColor]
								    forKey:NSBackgroundColorAttributeName]];
}

- (NSFont *)font
{
	return [ViThemeStore font];
}

- (void)setTypingAttributes:(NSDictionary *)attributes
{
	if ([self isFieldEditor])
		[super setTypingAttributes:attributes];
}

- (NSDictionary *)typingAttributes
{
	if ([self isFieldEditor])
		return [super typingAttributes];
	return [document typingAttributes];
}

- (NSUInteger)currentLine
{
	return [[self textStorage] lineNumberAtLocation:[self caret]];
}

- (NSUInteger)currentColumn
{
	return [[self textStorage] columnAtLocation:[self caret]];
}

/* syntax: ctrl-P */
- (BOOL)show_scope:(ViCommand *)command
{
	MESSAGE(@"%@", [[self scopesAtLocation:[self caret]] componentsJoinedByString:@" "]);
	return NO;
}

- (void)pushLocationOnJumpList:(NSUInteger)aLocation
{
	ViJumpList *jumplist = [[[self window] windowController] jumpList];
	[jumplist pushURL:[document fileURL]
		     line:[[self textStorage] lineNumberAtLocation:aLocation]
		   column:[[self textStorage] columnAtLocation:aLocation]
		     view:self];
}

- (void)pushCurrentLocationOnJumpList
{
	[self pushLocationOnJumpList:[self caret]];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
	NSMenu *menu = [self menuForEvent:theEvent];
	NSString *title = [[document language] displayName];
	NSMenuItem *item = title ? [menu itemWithTitle:title] : nil;
	if (item) {
		NSPoint event_location = [theEvent locationInWindow];
		NSPoint local_point = [self convertPoint:event_location fromView:nil];
		[menu popUpMenuPositioningItem:item atLocation:local_point inView:self];
	} else
		[NSMenu popUpContextMenu:menu withEvent:theEvent forView:self];

	/*
	 * Must remove the bundle menu items, otherwise the key equivalents
	 * remain active and interfere with the handling in keyDown:.
	 */
	[menu removeAllItems];
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent atLocation:(NSUInteger)location
{
	NSMenu *menu = [super menuForEvent:theEvent];
	int n = 0;

	NSArray *scopes = [self scopesAtLocation:location];
	NSRange sel = [self selectedRange];
	NSMenuItem *item;
	NSMenu *submenu;

	for (ViBundle *bundle in [[ViBundleStore defaultStore] allBundles]) {
		submenu = [bundle menuForScopes:scopes
				   hasSelection:sel.length > 0
					   font:[menu font]];
		if (submenu) {
			item = [menu insertItemWithTitle:[bundle name]
						  action:NULL
					   keyEquivalent:@""
						 atIndex:n++];
			[item setSubmenu:submenu];
		}
	}

	if (n > 0)
		[menu insertItem:[NSMenuItem separatorItem] atIndex:n++];

	ViLanguage *curLang = [document language];

	submenu = [[NSMenu alloc] initWithTitle:@"Language syntax"];
	item = [menu insertItemWithTitle:@"Language syntax"
				  action:NULL
			   keyEquivalent:@""
				 atIndex:n++];
	[item setSubmenu:submenu];

	item = [submenu addItemWithTitle:@"Unknown"
				  action:@selector(setLanguageAction:)
			   keyEquivalent:@""];
	[item setTag:1001];
	[item setEnabled:NO];
	if (curLang == nil)
		[item setState:NSOnState];
	[submenu addItem:[NSMenuItem separatorItem]];

	NSArray *languages = [[ViBundleStore defaultStore] languages];
	NSSortDescriptor *descriptor = [[NSSortDescriptor alloc] initWithKey:@"displayName" ascending:YES];
	NSArray *sortedLanguages = [languages sortedArrayUsingDescriptors:[NSArray arrayWithObject:descriptor]];

	for (ViLanguage *lang in sortedLanguages) {
		item = [submenu addItemWithTitle:[lang displayName]
					  action:@selector(setLanguageAction:)
				   keyEquivalent:@""];
		[item setRepresentedObject:lang];
		if (curLang == lang)
			[item setState:NSOnState];
	}

	if ([languages count] > 0)
		[submenu addItem:[NSMenuItem separatorItem]];
	[submenu addItemWithTitle:@"Get more bundles..."
			   action:@selector(getMoreBundles:)
		    keyEquivalent:@""];

	[menu insertItem:[NSMenuItem separatorItem] atIndex:n];

	return menu;
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent
{
	NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
	NSInteger charIndex = [self characterIndexForInsertionAtPoint:point];
	if (charIndex == NSNotFound)
		return [super menuForEvent:theEvent];

	[self setCaret:charIndex];
	return [self menuForEvent:theEvent atLocation:charIndex];
}

- (IBAction)performNormalModeMenuItem:(id)sender
{
	if (keyManager.parser.partial) {
		[[[[self window] windowController] nextRunloop] message:@"Vi command interrupted."];
		[keyManager.parser reset];
	}

	ViCommandMenuItemView *view = (ViCommandMenuItemView *)[sender view];
	if (view) {
		NSString *command = view.command;
		if (command) {
			if (mode == ViInsertMode)
				[self setNormalMode];
			DEBUG(@"performing command: %@", command);
			[self input:command];
		}
	}
}

- (BOOL)show_bundle_menu:(ViCommand *)command
{
	showingContextMenu = YES;	/* XXX: this disables the selection caused by NSMenu. */
	[self rightMouseDown:[self popUpContextEvent]];
	showingContextMenu = NO;
	return YES;
}

- (NSEvent *)popUpContextEvent
{
	NSPoint point = [[self layoutManager] boundingRectForGlyphRange:NSMakeRange([self caret], 0)
							inTextContainer:[self textContainer]].origin;
	NSEvent *ev = [NSEvent mouseEventWithType:NSRightMouseDown
			  location:[self convertPoint:point toView:nil]
		     modifierFlags:0
			 timestamp:[[NSDate date] timeIntervalSinceNow]
		      windowNumber:[[self window] windowNumber]
			   context:[NSGraphicsContext currentContext]
		       eventNumber:0
			clickCount:1
			  pressure:1.0];
	return ev;
}

- (void)popUpContextMenu:(NSMenu *)menu
{
	showingContextMenu = YES;	/* XXX: this disables the selection caused by NSMenu. */
	[NSMenu popUpContextMenu:menu withEvent:[self popUpContextEvent] forView:self];
	showingContextMenu = NO;
}

- (NSDictionary *)environment
{
	NSMutableDictionary *env = [NSMutableDictionary dictionary];
	[ViBundle setupEnvironment:env forTextView:self];
	return env;
}

@end


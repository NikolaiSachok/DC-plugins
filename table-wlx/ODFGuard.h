/* Preflight ODF expansion BEFORE SheetJS materializes repeated cells.
 * Trailing blank repetitions are common in LibreOffice files and do not
 * materialize cells. Nonempty repeats and repeated spaces have strict budgets.
 */
@interface TVODFGuard : NSObject <NSXMLParserDelegate>
@property(nonatomic) BOOL safe, inCell, materialized;
@property(nonatomic) NSUInteger rowRepeat, colRepeat, allocations, sheets, cellCharacters, totalCharacters;
@end
@implementation TVODFGuard
- (instancetype)init { if ((self=[super init])) { _safe=YES; _rowRepeat=_colRepeat=1; } return self; }
- (void)reject:(NSXMLParser *)parser { self.safe=NO; [parser abortParsing]; }
- (NSUInteger)count:(NSString *)value parser:(NSXMLParser *)parser {
    if (!value) return 1;
    NSScanner *scanner=[NSScanner scannerWithString:value]; unsigned long long count=0;
    if (![scanner scanUnsignedLongLong:&count] || !scanner.isAtEnd || count<1 || count>1000000000) {
        [self reject:parser]; return 1;
    }
    return (NSUInteger)count;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *,NSString *> *)attributes {
    (void)uri; (void)qualified;
    NSString *name=[element componentsSeparatedByString:@":"].lastObject;
    /* SheetJS accepts legacy aliases and strips underscore suffixes. Those
     * spellings are outside the ODF format we support; reject rather than
     * giving the guard and decoder different interpretations of the XML. */
    if ([name containsString:@"_"] || ![name canBeConvertedToEncoding:NSASCIIStringEncoding]) { [self reject:parser]; return; }
    NSMutableDictionary *attrs=[NSMutableDictionary dictionary];
    BOOL typedValue=NO;
    for (NSString *key in attributes) {
        NSString *local=[[key componentsSeparatedByString:@":"].lastObject lowercaseString];
        if ([local containsString:@"_"] || ![local canBeConvertedToEncoding:NSASCIIStringEncoding]) { [self reject:parser]; return; }
        if (attrs[local] && [@[@"number-rows-repeated",@"number-columns-repeated",@"c"] containsObject:local]) {
            [self reject:parser]; return;
        }
        if ([local isEqual:@"value-type"] && ![attributes[key] isEqual:@"string"]) typedValue=YES;
        attrs[local]=attributes[key];
    }
    if ([name isEqual:@"table"] && ++self.sheets>128) [self reject:parser];
    if ([name isEqual:@"table-row"]) self.rowRepeat=[self count:attrs[@"number-rows-repeated"] parser:parser];
    if ([name isEqual:@"table-cell"]) {
        self.inCell=YES;
        self.colRepeat=[self count:attrs[@"number-columns-repeated"] parser:parser];
        self.cellCharacters=[attrs[@"string-value"] length];
        self.materialized=typedValue || self.cellCharacters>0;
    }
    if (self.inCell && [name isEqual:@"p"]) self.materialized=YES;
    if ([name isEqual:@"s"]) {
        NSUInteger count=[self count:attrs[@"c"] parser:parser];
        if (count>32768) { [self reject:parser]; return; }
        if (self.inCell) self.cellCharacters+=count;
        else self.totalCharacters+=count;
    }
    if (self.inCell && [@[@"p",@"tab",@"line-break"] containsObject:name]) self.cellCharacters++;
    if (self.cellCharacters>32768 || self.totalCharacters>16000000) [self reject:parser];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
    (void)uri; (void)qualified;
    if (![[element componentsSeparatedByString:@":"].lastObject isEqual:@"table-cell"]) return;
    if (self.materialized) {
        if (self.rowRepeat>100001 || self.colRepeat>512 || self.rowRepeat*self.colRepeat>2000000-self.allocations)
            [self reject:parser];
        else {
            NSUInteger multiplier=self.rowRepeat*self.colRepeat;
            self.allocations+=multiplier;
            if (self.cellCharacters>32768 || self.cellCharacters*multiplier>16000000-self.totalCharacters)
                [self reject:parser];
            else self.totalCharacters+=self.cellCharacters*multiplier;
        }
    }
    self.inCell=NO; self.cellCharacters=0;
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)text {
    if (self.inCell) {
        self.cellCharacters+=text.length;
        if (self.cellCharacters>32768) [self reject:parser];
    }
}
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data {
    if (self.inCell) {
        self.cellCharacters+=data.length;
        if (self.cellCharacters>32768) [self reject:parser];
    }
}
@end
static BOOL CheckODFXML(NSData *data) {
    NSString *xml=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
                  [[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding];
    if (!xml || [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
                [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location!=NSNotFound) return NO;
    NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];
    parser.shouldResolveExternalEntities=NO;
    TVODFGuard *guard=[[TVODFGuard alloc] init]; parser.delegate=guard;
    return [parser parse] && guard.safe;
}

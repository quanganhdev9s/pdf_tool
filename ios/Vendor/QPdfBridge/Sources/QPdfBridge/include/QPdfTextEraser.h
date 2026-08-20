#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const QPdfBridgeErrorDomain;

typedef NS_ERROR_ENUM(QPdfBridgeErrorDomain, QPdfBridgeError) {
  QPdfBridgeErrorOpenFailed = 1,
  QPdfBridgeErrorWriteFailed = 2,
  QPdfBridgeErrorPageOutOfRange = 3,
};

/// Removes text from a page by deleting the operators that draw it.
///
/// PDFKit can only add annotations; there is no public API on iOS for editing
/// the operators a page is made of. So covering text with a filled rectangle is
/// the only thing PDFKit alone can do, and the words stay in the file
/// underneath the patch — still found by search, still yielded by copy, still
/// extracted by anything that reads content streams. This class is how the
/// words are actually removed instead of hidden.
///
/// The unit of removal is the *operator*, not the character. A page's content
/// stream shows text with `Tj`, `TJ`, `'` and `"`; each of these is identified
/// by its ordinal position among the text-showing operators on that page,
/// counting from zero in the order the page draws them. `PdfContentStreamReader`
/// on the Swift side assigns exactly the same ordinals while it walks the page
/// with `CGPDFScanner`, which is what lets a tap on a paragraph turn into a set
/// of numbers this class understands.
///
/// Two parsers agreeing on a numbering is an assumption, not a fact, so
/// `showTextOperatorCountAtURL:page:error:` exists to check it: if qpdf and
/// CoreGraphics do not report the same number of operators for a page, the
/// ordinals cannot be trusted and nothing should be deleted.
@interface QPdfTextEraser : NSObject

/// Writes `inputURL` to `outputURL` with the named operators removed.
///
/// `plan` maps a zero-based page index to the ordinals to drop on that page.
/// Pages absent from the plan are copied through untouched.
///
/// Dropping a text-showing operator moves nothing else on the page *provided*
/// every operator that follows it, up to the next one that moves the text line
/// matrix, is dropped as well — showing text advances the text matrix but never
/// the text *line* matrix, and `Td`, `TD`, `Tm`, `T*`, `'` and `"` all derive
/// their new position from the line matrix. Deciding that is the caller's job;
/// see `PdfContentStreamReader.deletionPlan(for:on:)`, which refuses to produce
/// a plan that would shift surviving text.
///
/// `'` and `"` are the exception, because they begin a new line as well as
/// draw: they are replaced by the positioning they performed rather than
/// erased, or every line below them slides up the page.
///
/// @param qdfMode  writes uncompressed, human-readable content streams. For
///                 development only: it roughly doubles file size, but it makes
///                 the result diffable against the input, which is the only
///                 practical way to see what a filter actually did.
+ (BOOL)eraseAtURL:(NSURL *)inputURL
             toURL:(NSURL *)outputURL
              plan:(NSDictionary<NSNumber *, NSArray<NSNumber *> *> *)plan
           qdfMode:(BOOL)qdfMode
             error:(NSError **)error;

/// Removes the named operators and lays an overlay's pages over the result, in
/// one pass.
///
/// The other half of editing text. `PdfTextOverlay` draws the replacement into
/// a PDF of its own — CoreGraphics embeds the fonts it used, which is the whole
/// reason the drawing happens over there — and this splices those pages into
/// this one's content. Erase and overlay together, because they are one edit
/// and because a document should never exist in a state where the old words are
/// gone and the new ones have not arrived.
///
/// `overlayPages[i]` is the zero-based index, in `inputURL`, of the page that
/// page `i` of `overlayURL` belongs over. Pass nil for both to erase only.
///
/// The overlay page is placed as a form XObject, which is qpdf's supported
/// route and keeps the original page's own content untouched byte for byte —
/// no image is re-encoded and no link is lost. The cost is that text inside a
/// form XObject is invisible to `PdfContentStreamReader`, which walks only the
/// page's own streams, so a block written this way cannot yet be picked or
/// erased a second time. Teaching both scanners to descend into form XObjects
/// removes that limit and the same blind spot on documents that arrive with
/// XObjects of their own.
+ (BOOL)eraseAtURL:(NSURL *)inputURL
             toURL:(NSURL *)outputURL
              plan:(NSDictionary<NSNumber *, NSArray<NSNumber *> *> *)plan
        overlayURL:(nullable NSURL *)overlayURL
      overlayPages:(nullable NSArray<NSNumber *> *)overlayPages
           qdfMode:(BOOL)qdfMode
             error:(NSError **)error;

/// Reads `inputURL` and writes it straight back out, changing nothing.
///
/// The first thing to get working, and worth keeping afterwards. qpdf rewrites
/// a file's structure wholesale rather than appending an incremental update, so
/// a document that survives this round trip intact is evidence that the object
/// model was understood; one that does not would have been corrupted by any
/// edit, and the bug would have looked like the edit's fault.
+ (BOOL)rewriteAtURL:(NSURL *)inputURL
               toURL:(NSURL *)outputURL
             qdfMode:(BOOL)qdfMode
               error:(NSError **)error;

/// How many text-showing operators qpdf finds on a page.
///
/// The agreement check described above. Call it before trusting a plan.
/// Returns -1 on error.
+ (NSInteger)showTextOperatorCountAtURL:(NSURL *)inputURL
                                   page:(NSInteger)pageIndex
                                  error:(NSError **)error;

/// Number of pages, or -1 on error.
+ (NSInteger)pageCountAtURL:(NSURL *)inputURL error:(NSError **)error;

/// The qpdf version this was built against, e.g. `"12.4.0"`.
@property (class, nonatomic, readonly) NSString *qpdfVersion;

@end

NS_ASSUME_NONNULL_END

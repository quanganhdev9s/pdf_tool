#import "QPdfTextEraser.h"

#include "QPdfShowTextFilters.hpp"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/Pl_Discard.hh>

#include <exception>
#include <memory>
#include <set>
#include <string>

NSErrorDomain const QPdfBridgeErrorDomain = @"QPdfBridgeErrorDomain";

using qpdfbridge::CountShowText;
using qpdfbridge::DropShowText;

namespace {

NSError*
errorWithCode(QPdfBridgeError code, std::string const& message)
{
    return [NSError errorWithDomain:QPdfBridgeErrorDomain
                               code:code
                           userInfo:@{
                             NSLocalizedDescriptionKey:
                               [NSString stringWithUTF8String:message.c_str()]
                           }];
}

} // namespace

@implementation QPdfTextEraser

+ (NSString*)qpdfVersion
{
    return [NSString stringWithUTF8String:QPDF::QPDFVersion().c_str()];
}

+ (BOOL)eraseAtURL:(NSURL*)inputURL
             toURL:(NSURL*)outputURL
              plan:(NSDictionary<NSNumber*, NSArray<NSNumber*>*>*)plan
           qdfMode:(BOOL)qdfMode
             error:(NSError**)error
{
    return [self eraseAtURL:inputURL
                      toURL:outputURL
                       plan:plan
                       hide:nil
                 overlayURL:nil
               overlayPages:nil
                    qdfMode:qdfMode
                      error:error];
}

+ (BOOL)eraseAtURL:(NSURL*)inputURL
             toURL:(NSURL*)outputURL
              plan:(NSDictionary<NSNumber*, NSArray<NSNumber*>*>*)plan
              hide:(NSDictionary<NSNumber*, NSDictionary<NSNumber*, NSNumber*>*>*)hide
        overlayURL:(NSURL*)overlayURL
      overlayPages:(NSArray<NSNumber*>*)overlayPages
           qdfMode:(BOOL)qdfMode
             error:(NSError**)error
{
    try {
        QPDF pdf;
        pdf.processFile(inputURL.path.UTF8String);

        QPDFPageDocumentHelper documents(pdf);
        auto pages = documents.getAllPages();

        // Pages named by either half of the request. A page can be hidden on
        // without anything being dropped from it, and the other way round.
        NSMutableSet<NSNumber*>* touched = [NSMutableSet setWithArray:plan.allKeys];
        if (hide != nil) {
            [touched addObjectsFromArray:hide.allKeys];
        }

        for (NSNumber* key in touched) {
            NSInteger const pageIndex = key.integerValue;
            if (pageIndex < 0 || static_cast<size_t>(pageIndex) >= pages.size()) {
                if (error) {
                    *error = errorWithCode(
                        QPdfBridgeErrorPageOutOfRange,
                        "page " + std::to_string(pageIndex) + " is not in this document");
                }
                return NO;
            }
            std::set<size_t> targets;
            for (NSNumber* ordinal in plan[key]) {
                if (ordinal.integerValue >= 0) {
                    targets.insert(static_cast<size_t>(ordinal.integerValue));
                }
            }

            std::map<size_t, int> hidden;
            for (NSNumber* ordinal in hide[key]) {
                if (ordinal.integerValue >= 0) {
                    hidden[static_cast<size_t>(ordinal.integerValue)] =
                        hide[key][ordinal].intValue;
                }
            }

            if (targets.empty() && hidden.empty()) {
                continue;
            }
            // The filter runs when QPDFWriter serialises the page, not now.
            pages[static_cast<size_t>(pageIndex)].addContentTokenFilter(
                std::make_shared<DropShowText>(std::move(targets), std::move(hidden)));
        }

        // The overlay is opened only once there is something to lay over, and
        // it is kept alive until after the write: qpdf resolves copied stream
        // data lazily from the source it came from, so letting this go early
        // would write empty streams.
        QPDF overlay;
        if (overlayURL != nil && overlayPages.count > 0) {
            overlay.processFile(overlayURL.path.UTF8String);
            QPDFPageDocumentHelper overlayDocuments(overlay);
            auto overlayPageList = overlayDocuments.getAllPages();

            if (overlayPageList.size() != overlayPages.count) {
                if (error) {
                    *error = errorWithCode(
                        QPdfBridgeErrorPageOutOfRange,
                        "overlay has " + std::to_string(overlayPageList.size()) +
                            " pages but " + std::to_string(overlayPages.count) +
                            " placements were given");
                }
                return NO;
            }

            for (NSUInteger i = 0; i < overlayPages.count; ++i) {
                NSInteger const target = overlayPages[i].integerValue;
                if (target < 0 || static_cast<size_t>(target) >= pages.size()) {
                    if (error) {
                        *error = errorWithCode(
                            QPdfBridgeErrorPageOutOfRange,
                            "overlay names page " + std::to_string(target) +
                                ", which is not in this document");
                    }
                    return NO;
                }

                auto& destination = pages[static_cast<size_t>(target)];
                QPDFObjectHandle foreign = overlayPageList[i].getFormXObjectForPage();
                QPDFObjectHandle fo = pdf.copyForeignObject(foreign);

                QPDFObjectHandle resources =
                    destination.getObjectHandle().getKey("/Resources");
                if (!resources.isDictionary()) {
                    resources = QPDFObjectHandle::newDictionary();
                    destination.getObjectHandle().replaceKey("/Resources", resources);
                }

                int suffix = 1;
                std::string const name = resources.getUniqueResourceName("/Fx", suffix);

                // Onto the page's own media box, at its own size: the overlay
                // was drawn against exactly this rectangle, so this places it
                // one to one rather than fitting it to anything.
                std::string const content = destination.placeFormXObject(
                    fo,
                    name,
                    destination.getMediaBox().getArrayAsRectangle(),
                    /*invert_transformations=*/true,
                    /*allow_shrink=*/true,
                    /*allow_expand=*/false);
                if (content.empty()) {
                    continue;
                }

                resources.mergeResources(
                    QPDFObjectHandle::parse("<< /XObject << >> >>"));
                resources.getKey("/XObject").replaceKey(name, fo);

                // Wrapped in q/Q and bracketed around the page's existing
                // content, so the overlay inherits none of the graphics state
                // the page left behind and leaves none of its own.
                destination.addPageContents(pdf.newStream("q\n"), true);
                destination.addPageContents(pdf.newStream("\nQ\n" + content), false);
            }
        }

        QPDFWriter writer(pdf, outputURL.path.UTF8String);
        writer.setQDFMode(qdfMode ? true : false);
        writer.write();
        return YES;
    } catch (std::exception const& e) {
        if (error) {
            *error = errorWithCode(QPdfBridgeErrorWriteFailed, e.what());
        }
        return NO;
    }
}

+ (BOOL)rewriteAtURL:(NSURL*)inputURL
               toURL:(NSURL*)outputURL
             qdfMode:(BOOL)qdfMode
               error:(NSError**)error
{
    return [self eraseAtURL:inputURL
                      toURL:outputURL
                       plan:@{}
                    qdfMode:qdfMode
                      error:error];
}

+ (NSInteger)showTextOperatorCountAtURL:(NSURL*)inputURL
                                   page:(NSInteger)pageIndex
                                  error:(NSError**)error
{
    try {
        QPDF pdf;
        pdf.processFile(inputURL.path.UTF8String);

        QPDFPageDocumentHelper documents(pdf);
        auto pages = documents.getAllPages();
        if (pageIndex < 0 || static_cast<size_t>(pageIndex) >= pages.size()) {
            if (error) {
                *error = errorWithCode(
                    QPdfBridgeErrorPageOutOfRange,
                    "page " + std::to_string(pageIndex) + " is not in this document");
            }
            return -1;
        }

        CountShowText counter;
        Pl_Discard discard;
        pages[static_cast<size_t>(pageIndex)].filterContents(&counter, &discard);
        return static_cast<NSInteger>(counter.count);
    } catch (std::exception const& e) {
        if (error) {
            *error = errorWithCode(QPdfBridgeErrorOpenFailed, e.what());
        }
        return -1;
    }
}

+ (NSInteger)pageCountAtURL:(NSURL*)inputURL error:(NSError**)error
{
    try {
        QPDF pdf;
        pdf.processFile(inputURL.path.UTF8String);
        return static_cast<NSInteger>(QPDFPageDocumentHelper(pdf).getAllPages().size());
    } catch (std::exception const& e) {
        if (error) {
            *error = errorWithCode(QPdfBridgeErrorOpenFailed, e.what());
        }
        return -1;
    }
}

@end

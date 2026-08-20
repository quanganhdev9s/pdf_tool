// A host-runnable exercise of the filters in QPdfShowTextFilters.hpp — the
// same header the iOS bridge compiles, not a copy of it.
//
// Deleting operators by ordinal is the kind of thing that fails quietly: get
// the numbering wrong by one and the wrong sentence disappears, and the file is
// still perfectly valid PDF. So the filter is tested where a test can actually
// read the result — on the host, against a document whose content stream was
// written by hand precisely so that it contains the operators a real-world PDF
// rarely does (`'` and `"`), which are the two that cannot simply be dropped.
//
//   usage: filter_test <in.pdf> <out.pdf> [ordinal ...]
//   prints: the operator count, then the number dropped

#include "../Sources/QPdfBridge/QPdfShowTextFilters.hpp"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/Pl_Discard.hh>

#include <cstdlib>
#include <iostream>
#include <memory>
#include <set>

int
main(int argc, char** argv)
{
    if (argc < 3) {
        std::cerr << "usage: " << argv[0] << " <in.pdf> <out.pdf> [ordinal ...]\n";
        return 2;
    }
    char const* input = argv[1];
    char const* output = argv[2];

    std::set<size_t> targets;
    for (int i = 3; i < argc; ++i) {
        targets.insert(static_cast<size_t>(std::atoi(argv[i])));
    }

    try {
        {
            QPDF pdf;
            pdf.processFile(input);
            auto pages = QPDFPageDocumentHelper(pdf).getAllPages();
            qpdfbridge::CountShowText counter;
            Pl_Discard discard;
            pages.at(0).filterContents(&counter, &discard);
            std::cout << "count=" << counter.count << "\n";
        }

        QPDF pdf;
        pdf.processFile(input);
        auto pages = QPDFPageDocumentHelper(pdf).getAllPages();
        auto filter = std::make_shared<qpdfbridge::DropShowText>(targets);
        pages.at(0).addContentTokenFilter(filter);

        QPDFWriter writer(pdf, output);
        writer.setQDFMode(true); // so the test can read the result
        writer.write();

        std::cout << "dropped=" << filter->droppedCount() << "\n";
        return 0;
    } catch (std::exception const& e) {
        std::cerr << "error: " << e.what() << "\n";
        return 1;
    }
}

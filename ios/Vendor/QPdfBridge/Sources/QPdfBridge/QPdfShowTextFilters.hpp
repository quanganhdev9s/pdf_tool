#pragma once

// The content-stream filters, kept free of Objective-C so that
// tools/filter_test.cpp can exercise exactly the code that ships rather than a
// reimplementation of it. Deleting the wrong operator silently removes the
// wrong words, and a test that only resembles the shipping filter would not
// catch that.

#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFTokenizer.hh>

#include <set>
#include <string>
#include <utility>
#include <vector>

namespace qpdfbridge {

inline bool
isShowTextOperator(std::string const& op)
{
    return op == "Tj" || op == "TJ" || op == "'" || op == "\"";
}

/// Passes a content stream through unchanged while counting how many
/// text-showing operators it contains.
class CountShowText final: public QPDFObjectHandle::TokenFilter
{
  public:
    void
    handleToken(QPDFTokenizer::Token const& token) override
    {
        if (token.getType() == QPDFTokenizer::tt_word &&
            isShowTextOperator(token.getValue())) {
            ++count;
        }
        writeToken(token);
    }

    size_t count{0};
};

/// Drops the text-showing operators whose ordinals appear in `targets`.
///
/// The filter sees tokens, not operations, and an operator arrives *after* its
/// operands — by the time `Tj` shows up, the string it draws has already gone
/// past. So operands are buffered and only released once the operator that
/// consumes them turns out to be one worth keeping. Dropping an operator means
/// dropping the buffer with it.
class DropShowText final: public QPDFObjectHandle::TokenFilter
{
  public:
    explicit DropShowText(std::set<size_t> targets):
        targets(std::move(targets))
    {
    }

    void
    handleToken(QPDFTokenizer::Token const& token) override
    {
        auto const type = token.getType();
        if (type == QPDFTokenizer::tt_eof) {
            flush();
            return;
        }
        if (type != QPDFTokenizer::tt_word) {
            pending.push_back(token);
            return;
        }

        std::string const op = token.getValue();
        if (!isShowTextOperator(op)) {
            flush();
            writeToken(token);
            return;
        }

        // Every text-showing operator is numbered, including the ones drawn in
        // an invisible render mode. A scanned page carries its OCR layer in
        // mode 3 under the image, and leaving those out of the count here would
        // put this filter's ordinals out of step with the scanner's on the
        // Swift side, which numbers them the same way.
        size_t const ordinal = showIndex++;
        if (targets.find(ordinal) == targets.end()) {
            flush();
            writeToken(token);
            return;
        }
        ++dropped;

        // `Tj` and `TJ` only advance the text matrix, and the caller has
        // already established that nothing surviving depends on that advance,
        // so they can disappear along with their operands.
        //
        // `'` and `"` also begin a new line, and that has to happen whether or
        // not the words are drawn — otherwise every line below slides up. They
        // are replaced by the positioning they performed:
        //
        //     (s) '            ->  T*
        //     aw ac (s) "      ->  aw Tw ac Tc T*
        //
        // Every replacement opens with a newline. Dropping an operator drops
        // the buffered tokens with it, and the whitespace that separated this
        // operator's operands from whatever preceded them is in that buffer —
        // so without a fresh separator the replacement fuses onto the previous
        // token. `'` followed by `T*` becomes the single word `'T*`, which is
        // not an operator at all, and the page quietly stops advancing lines.
        if (op == "'") {
            write("\nT*\n");
        } else if (op == "\"") {
            auto const operands = significantOperands();
            if (operands.size() >= 3) {
                // ... aw ac string "
                write("\n");
                writeToken(operands[operands.size() - 3]);
                write(" Tw ");
                writeToken(operands[operands.size() - 2]);
                write(" Tc T*\n");
            } else {
                // Malformed, but the line break is the part that moves things.
                write("\nT*\n");
            }
        }
        pending.clear();
    }

    void
    handleEOF() override
    {
        flush();
    }

    size_t droppedCount() const
    {
        return dropped;
    }

  private:
    void
    flush()
    {
        for (auto const& token: pending) {
            writeToken(token);
        }
        pending.clear();
    }

    /// The buffered operands with whitespace and comments removed, so that
    /// counting back from the end means what it looks like it means.
    std::vector<QPDFTokenizer::Token>
    significantOperands() const
    {
        std::vector<QPDFTokenizer::Token> result;
        for (auto const& token: pending) {
            auto const type = token.getType();
            if (type != QPDFTokenizer::tt_space &&
                type != QPDFTokenizer::tt_comment) {
                result.push_back(token);
            }
        }
        return result;
    }

    std::set<size_t> targets;
    size_t showIndex{0};
    size_t dropped{0};
    std::vector<QPDFTokenizer::Token> pending;
};

} // namespace qpdfbridge

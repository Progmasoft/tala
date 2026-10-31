// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <bit>

#include "Format.hpp"
#include "Progmasoft/Tala/Runtime/Text.h"

namespace Progmasoft::Tala::Runtime::Text
{
    namespace
    {
        /// The field a conversion writes: what stands before the digits,
        /// the body, and the padding that brings the two to the width.
        ///
        /// Padding stands at the left unless the conversion asks for the
        /// value at the left. Zeros, which only a number may ask for, stand
        /// between the prefix and the body, so that a sign stays in front.
        void
        AppendField(Scalars &output,
                    const char *prefix,
                    const Scalars &body,
                    const Conversion &conversion,
                    const bool zerosAllowed) noexcept
        {
            std::size_t prefixSize = 0U;
            while (prefix[prefixSize] != '\0')
                ++prefixSize;
            const auto size = prefixSize + body.Size();
            // A width the value already fills, and a width that is absent
            // or negative, add nothing.
            const auto padding
                = conversion.width > 0
                          && static_cast<std::uint64_t>(conversion.width) > size
                      ? static_cast<std::size_t>(
                            static_cast<std::uint64_t>(conversion.width) - size)
                      : std::size_t{ 0U };
            const auto left = conversion.Has(TALA_TEXT_FLAG_LEFT);
            const auto zeros
                = zerosAllowed && !left && conversion.Has(TALA_TEXT_FLAG_ZERO);
            if (!left && !zeros)
                output.Fill(U' ', padding);
            output.AppendAscii(prefix);
            if (zeros)
                output.Fill(U'0', padding);
            output.Append(body.Data(), body.Size());
            if (left)
                output.Fill(U' ', padding);
        }

        /// The sign a number is written with: a minus when it is negative,
        /// and otherwise what the conversion asks for, if anything.
        [[nodiscard]] auto
        Sign(const bool negative, const Conversion &conversion) noexcept
            -> const char *
        {
            if (negative)
                return "-";
            if (conversion.Has(TALA_TEXT_FLAG_PLUS))
                return "+";
            if (conversion.Has(TALA_TEXT_FLAG_SPACE))
                return " ";
            return "";
        }

        /// A natural number of bounded size, for the exact decimal
        /// expansion of a floating-point value.
        ///
        /// A finite `double` is an integer of at most 53 bits times a power
        /// of two between 2^-1074 and 2^971. Scaled by 10^1074 it is an
        /// integer below 2^4592, which is what the capacity is chosen for;
        /// nothing here rounds or estimates.
        class Natural final
        {
        public:
            explicit Natural(const std::uint64_t value) noexcept
            {
                limbs_[0] = static_cast<std::uint32_t>(value & 0xffffffffULL);
                limbs_[1] = static_cast<std::uint32_t>(value >> 32U);
                used_ = limbs_[1] != 0U ? 2U : limbs_[0] != 0U ? 1U : 0U;
            }

            [[nodiscard]] auto
            IsZero() const noexcept -> bool
            {
                return used_ == 0U;
            }

            void
            Multiply(const std::uint32_t factor) noexcept
            {
                std::uint64_t carry = 0U;
                for (std::size_t index = 0U; index < used_; ++index)
                {
                    const auto product
                        = static_cast<std::uint64_t>(limbs_[index]) * factor
                          + carry;
                    limbs_[index]
                        = static_cast<std::uint32_t>(product & 0xffffffffULL);
                    carry = product >> 32U;
                }
                if (carry != 0U)
                    Push(static_cast<std::uint32_t>(carry));
            }

            void
            ShiftLeft(const std::size_t bits) noexcept
            {
                if (used_ == 0U || bits == 0U)
                    return;
                const auto whole = bits / 32U;
                const auto part = static_cast<unsigned>(bits % 32U);
                if (used_ + whole + 1U > kLimbs)
                    Platform::Fail();
                std::uint32_t carried = 0U;
                if (part != 0U)
                    for (std::size_t index = 0U; index < used_; ++index)
                    {
                        const auto limb = limbs_[index];
                        limbs_[index] = (limb << part) | carried;
                        carried = limb >> (32U - part);
                    }
                if (carried != 0U)
                    limbs_[used_++] = carried;
                if (whole != 0U)
                {
                    for (std::size_t index = used_; index-- > 0U;)
                        limbs_[index + whole] = limbs_[index];
                    for (std::size_t index = 0U; index < whole; ++index)
                        limbs_[index] = 0U;
                    used_ += whole;
                }
            }

            /// Divides by 2^bits and rounds to the nearest integer; a value
            /// exactly between two integers goes to the even one.
            void
            ShiftRightToNearestEven(const std::size_t bits) noexcept
            {
                if (bits == 0U || used_ == 0U)
                    return;
                const auto half = Bit(bits - 1U);
                auto below = false;
                for (std::size_t index = 0U;
                     !below && index < (bits - 1U) / 32U && index < used_;
                     ++index)
                    below = limbs_[index] != 0U;
                if (!below && (bits - 1U) % 32U != 0U
                    && (bits - 1U) / 32U < used_)
                    below = (limbs_[(bits - 1U) / 32U]
                             & ((1U << ((bits - 1U) % 32U)) - 1U))
                            != 0U;

                const auto whole = bits / 32U;
                const auto part = static_cast<unsigned>(bits % 32U);
                if (whole >= used_)
                {
                    used_ = 0U;
                }
                else
                {
                    for (std::size_t index = whole; index < used_; ++index)
                    {
                        auto limb = limbs_[index] >> part;
                        if (part != 0U && index + 1U < used_)
                            limb |= limbs_[index + 1U] << (32U - part);
                        limbs_[index - whole] = limb;
                    }
                    used_ -= whole;
                    while (used_ != 0U && limbs_[used_ - 1U] == 0U)
                        --used_;
                }
                const auto odd = used_ != 0U && (limbs_[0] & 1U) != 0U;
                if (half && (below || odd))
                    Increment();
            }

            /// Divides by a divisor and returns what remains.
            [[nodiscard]] auto
            Divide(const std::uint32_t divisor) noexcept -> std::uint32_t
            {
                std::uint64_t remainder = 0U;
                for (std::size_t index = used_; index-- > 0U;)
                {
                    const auto dividend = (remainder << 32U) | limbs_[index];
                    limbs_[index]
                        = static_cast<std::uint32_t>(dividend / divisor);
                    remainder = dividend % divisor;
                }
                while (used_ != 0U && limbs_[used_ - 1U] == 0U)
                    --used_;
                return static_cast<std::uint32_t>(remainder);
            }

        private:
            static constexpr std::size_t kLimbs = 160U;

            [[nodiscard]] auto
            Bit(const std::size_t position) const noexcept -> bool
            {
                const auto limb = position / 32U;
                return limb < used_
                       && ((limbs_[limb] >> (position % 32U)) & 1U) != 0U;
            }

            void
            Push(const std::uint32_t limb) noexcept
            {
                if (used_ == kLimbs)
                    Platform::Fail();
                limbs_[used_++] = limb;
            }

            void
            Increment() noexcept
            {
                for (std::size_t index = 0U; index < used_; ++index)
                    if (++limbs_[index] != 0U)
                        return;
                Push(1U);
            }

            std::uint32_t limbs_[kLimbs]{};
            std::size_t used_{};
        };

        /// The most digits after the point a finite `double` has: the
        /// expansion of 2^-1074 ends at its 1074th. Every digit asked for
        /// beyond that is a zero and is written without being computed.
        constexpr std::int64_t kExactFractionDigits = 1074;

        /// Appends integer digits, least significant first, with a group
        /// separator after every third when grouping is asked for.
        class ReversedDigits final
        {
        public:
            ReversedDigits(Scalars &digits, const bool grouped) noexcept
                : digits_(digits)
                , grouped_(grouped)
            {}

            void
            Append(const char32_t digit) noexcept
            {
                if (grouped_ && count_ != 0U && count_ % 3U == 0U)
                    digits_.Append(U'\'');
                digits_.Append(digit);
                ++count_;
            }

        private:
            Scalars &digits_;
            bool grouped_;
            std::size_t count_{};
        };
    } // namespace

    void
    AppendInteger(Scalars &output,
                  const bool negative,
                  std::uint64_t magnitude,
                  const Conversion &conversion) noexcept
    {
        const auto hexadecimal = conversion.Has(TALA_TEXT_FLAG_HEXADECIMAL);
        Scalars body;
        {
            ReversedDigits digits(body,
                                  !hexadecimal
                                      && conversion.Has(TALA_TEXT_FLAG_GROUP));
            const std::uint64_t base = hexadecimal ? 16U : 10U;
            do
            {
                const auto digit = static_cast<unsigned>(magnitude % base);
                digits.Append(static_cast<char32_t>(
                    digit < 10U ? U'0' + digit : U'a' + (digit - 10U)));
                magnitude /= base;
            } while (magnitude != 0U);
        }
        body.ReverseFrom(0U);

        // At most a sign and the two characters of the prefix.
        char prefix[4]{};
        std::size_t used = 0U;
        for (const auto *sign = Sign(negative, conversion); *sign != '\0';
             ++sign)
            prefix[used++] = *sign;
        if (hexadecimal && conversion.Has(TALA_TEXT_FLAG_ALTERNATE))
        {
            prefix[used++] = '0';
            prefix[used++] = 'x';
        }
        AppendField(output, prefix, body, conversion, true);
    }

    void
    AppendFloating(Scalars &output,
                   const double value,
                   const Conversion &conversion) noexcept
    {
        const auto bits = std::bit_cast<std::uint64_t>(value);
        const auto negative = (bits >> 63U) != 0U;
        const auto exponentField
            = static_cast<unsigned>((bits >> 52U) & 0x7ffU);
        const auto fraction = bits & ((std::uint64_t{ 1U } << 52U) - 1U);

        if (exponentField == 0x7ffU)
        {
            // Not a number has no sign worth writing; an infinity has.
            Scalars body;
            body.AppendAscii(fraction != 0U ? "nan" : "inf");
            AppendField(output,
                        fraction != 0U ? "" : Sign(negative, conversion),
                        body,
                        conversion,
                        false);
            return;
        }

        const auto precision = conversion.precision < 0 ? std::int64_t{ 6 }
                                                        : conversion.precision;
        const auto computed = precision < kExactFractionDigits
                                  ? precision
                                  : kExactFractionDigits;

        // The value is `significand * 2^exponent` exactly.
        const auto significand = exponentField == 0U
                                     ? fraction
                                     : fraction | (std::uint64_t{ 1U } << 52U);
        const int exponent = exponentField == 0U
                                 ? -1074
                                 : static_cast<int>(exponentField) - 1075;

        // `scaled` becomes the value times ten to the number of computed
        // digits, rounded to the nearest integer. Its decimal digits are
        // the digits of the result with the point left out.
        Natural scaled(significand);
        for (std::int64_t done = 0; done < computed;)
        {
            const auto step = computed - done >= 9 ? 9 : computed - done;
            std::uint32_t power = 1U;
            for (std::int64_t index = 0; index < step; ++index)
                power *= 10U;
            scaled.Multiply(power);
            done += step;
        }
        if (exponent >= 0)
            scaled.ShiftLeft(static_cast<std::size_t>(exponent));
        else
            scaled.ShiftRightToNearestEven(static_cast<std::size_t>(-exponent));

        // Fraction digits first, least significant first, then the integer
        // digits, which are the ones grouping applies to.
        Scalars body;
        for (std::int64_t index = computed; index < precision; ++index)
            body.Append(U'0');
        std::int64_t produced = 0;
        const auto nextDigit = [&scaled]() noexcept -> char32_t {
            return static_cast<char32_t>(U'0' + scaled.Divide(10U));
        };
        for (; produced < computed; ++produced)
            body.Append(nextDigit());
        if (precision > 0)
            body.Append(U'.');
        {
            ReversedDigits integer(body, conversion.Has(TALA_TEXT_FLAG_GROUP));
            do
            {
                integer.Append(nextDigit());
            } while (!scaled.IsZero());
        }
        body.ReverseFrom(0U);
        AppendField(output, Sign(negative, conversion), body, conversion, true);
    }

    void
    AppendText(Scalars &output,
               const char32_t *scalars,
               std::size_t count,
               const Conversion &conversion) noexcept
    {
        if (conversion.precision >= 0
            && static_cast<std::uint64_t>(conversion.precision) < count)
            count = static_cast<std::size_t>(conversion.precision);
        Scalars body;
        body.Append(scalars, count);
        AppendField(output, "", body, conversion, false);
    }
} // namespace Progmasoft::Tala::Runtime::Text

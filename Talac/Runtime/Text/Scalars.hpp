// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <new>

#include "Platform.hpp"

namespace Progmasoft::Tala::Runtime::Text
{
    /** A growing sequence of Unicode scalar values.
     *
     * The text routines build every result in one of these and turn it into
     * a string at the end. It is not a standard container on purpose: the
     * runtime is also compiled for executables that have no C runtime, and
     * a standard container reports failure through functions such an
     * executable does not have. Short results stay in the object; longer
     * ones move to memory from the non-throwing allocator, and a result
     * that cannot be allocated stops the program.
     */
    class Scalars final
    {
    public:
        Scalars() noexcept = default;
        Scalars(const Scalars &) = delete;
        Scalars(Scalars &&) = delete;
        auto
        operator=(const Scalars &) -> Scalars & = delete;
        auto
        operator=(Scalars &&) -> Scalars & = delete;

        ~Scalars()
        {
            if (data_ != inline_)
                ::operator delete(data_);
        }

        [[nodiscard]] auto
        Size() const noexcept -> std::size_t
        {
            return size_;
        }

        [[nodiscard]] auto
        Data() const noexcept -> const char32_t *
        {
            return data_;
        }

        void
        Append(const char32_t scalar) noexcept
        {
            Reserve(1U);
            data_[size_++] = scalar;
        }

        void
        Append(const char32_t *scalars, const std::size_t count) noexcept
        {
            Reserve(count);
            for (std::size_t index = 0U; index < count; ++index)
                data_[size_ + index] = scalars[index];
            size_ += count;
        }

        /// Appends the characters of a NUL-terminated ASCII text.
        void
        AppendAscii(const char *text) noexcept
        {
            for (; *text != '\0'; ++text)
                Append(
                    static_cast<char32_t>(static_cast<unsigned char>(*text)));
        }

        void
        Fill(const char32_t scalar, const std::size_t count) noexcept
        {
            Reserve(count);
            for (std::size_t index = 0U; index < count; ++index)
                data_[size_ + index] = scalar;
            size_ += count;
        }

        /// Reverses the scalars from `first` to the end.
        void
        ReverseFrom(const std::size_t first) noexcept
        {
            if (size_ < first + 2U)
                return;
            for (std::size_t low = first, high = size_ - 1U; low < high;
                 ++low, --high)
            {
                const auto kept = data_[low];
                data_[low] = data_[high];
                data_[high] = kept;
            }
        }

    private:
        static constexpr std::size_t kInline = 64U;

        void
        Reserve(const std::size_t more) noexcept
        {
            if (more <= capacity_ - size_)
                return;
            // Twice what is held, or what is asked for when that is more.
            // A size that does not fit the address space cannot be met.
            constexpr auto kLimit
                = static_cast<std::size_t>(-1) / sizeof(char32_t) / 2U;
            if (more > kLimit - size_)
                Platform::Fail();
            auto capacity = capacity_ * 2U;
            if (capacity < size_ + more)
                capacity = size_ + more;
            // The allocation function is called by name, as the ownership
            // runtime calls it for an object: what comes back is storage or
            // null, and null is the only report of failure there is in a
            // runtime built without exceptions. `capacity` is at most twice
            // `kLimit`, so the size in bytes does not wrap.
            auto *grown = static_cast<char32_t *>(
                ::operator new(capacity * sizeof(char32_t), std::nothrow));
            if (grown == nullptr)
                Platform::Fail();
            for (std::size_t index = 0U; index < size_; ++index)
                grown[index] = data_[index];
            if (data_ != inline_)
                ::operator delete(data_);
            data_ = grown;
            capacity_ = capacity;
        }

        char32_t inline_[kInline]{};
        char32_t *data_{ inline_ };
        std::size_t size_{};
        std::size_t capacity_{ kInline };
    };
} // namespace Progmasoft::Tala::Runtime::Text

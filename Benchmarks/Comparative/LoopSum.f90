! SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
! SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
!
! A deliberately small Fortran 2023 benchmark companion. The caller chooses
! one of two loop strategies or the arithmetic-series formula. The formula
! is an algorithmic control, not a like-for-like loop code-generation test.
program loop_sum
    use, intrinsic :: iso_fortran_env, only: int64, error_unit, output_unit
    implicit none

    character(len=32) :: algorithm
    character(len=32) :: count_text
    integer :: argument_status
    integer :: parse_status
    integer(int64) :: limit
    integer(int64) :: checksum
    integer(int64), parameter :: maximum_safe_limit = 4294967295_int64

    algorithm = "baseline"
    count_text = "50000000"
    if (command_argument_count() > 2) then
        call print_usage()
        stop 2
    end if

    if (command_argument_count() >= 1) then
        call get_command_argument(1, algorithm, status=argument_status)
        if (argument_status /= 0) then
            call print_usage()
            stop 2
        end if
    end if
    if (command_argument_count() == 2) then
        call get_command_argument(2, count_text, status=argument_status)
        if (argument_status /= 0) then
            call print_usage()
            stop 2
        end if
    end if

    read(count_text, *, iostat=parse_status) limit
    if (parse_status /= 0) then
        call print_usage()
        stop 2
    end if
    if (limit <= 0_int64 .or. limit > maximum_safe_limit) then
        call print_usage()
        stop 2
    end if

    select case (trim(algorithm))
    case ("baseline")
        checksum = sum_baseline(limit)
    case ("unrolled")
        checksum = sum_unrolled(limit)
    case ("formula")
        checksum = sum_formula(limit)
    case default
        call print_usage()
        stop 2
    end select

    write(output_unit, '(a,a,a,i0,a,i0)') &
        "algorithm=", trim(algorithm), " count=", limit, " checksum=", checksum

contains

    ! Keep the reference implementation intentionally serial: it is the
    ! control group for the four-accumulator implementation below.
    pure function sum_baseline(count) result(total)
        integer(int64), intent(in) :: count
        integer(int64) :: total
        integer(int64) :: value

        total = 0_int64
        do value = 1_int64, count
            total = total + value
        end do
    end function sum_baseline

    ! Independent accumulators shorten the dependency chain. The scalar tail
    ! preserves identical behavior when count is not divisible by four.
    pure function sum_unrolled(count) result(total)
        integer(int64), intent(in) :: count
        integer(int64) :: total
        integer(int64) :: first_sum
        integer(int64) :: second_sum
        integer(int64) :: third_sum
        integer(int64) :: fourth_sum
        integer(int64) :: value

        first_sum = 0_int64
        second_sum = 0_int64
        third_sum = 0_int64
        fourth_sum = 0_int64
        value = 1_int64

        do while (value <= count - 3_int64)
            first_sum = first_sum + value
            second_sum = second_sum + value + 1_int64
            third_sum = third_sum + value + 2_int64
            fourth_sum = fourth_sum + value + 3_int64
            value = value + 4_int64
        end do

        total = first_sum + second_sum + third_sum + fourth_sum
        do while (value <= count)
            total = total + value
            value = value + 1_int64
        end do
    end function sum_unrolled

    ! The greatest accepted input has an Int64-representable triangular sum.
    ! Divide whichever factor is even before multiplying to avoid overflow.
    pure function sum_formula(count) result(total)
        integer(int64), intent(in) :: count
        integer(int64) :: total

        if (mod(count, 2_int64) == 0_int64) then
            total = (count / 2_int64) * (count + 1_int64)
        else
            total = count * ((count + 1_int64) / 2_int64)
        end if
    end function sum_formula

    ! Use the Fortran standard error unit so malformed invocations never
    ! contaminate benchmark output captured by the timing harness.
    subroutine print_usage()
        write(error_unit, '(a)') &
            "usage: loop-sum-fortran [baseline|unrolled|formula] [count: 1..4294967295]"
    end subroutine print_usage

end program loop_sum

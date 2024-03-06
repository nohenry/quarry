//usr/bin/clang "$0" out.o && ./a.out; exit

#include <stdlib.h>
#include <stdio.h>

extern char root_main(char);

extern char root_test_array1(char);
extern char root_test_slice1(char);
// extern char root_test_array2(char);
extern char root_test_slice2(char);
extern char root_test_array3(char);
extern char root_test_slice3(char);
// extern char root_test_array4(char);

extern char root_test_record1(char);
extern char root_test_record2(char);
extern char root_test_record3(char);
extern char root_test_record4(char);

#define ASSERT_EQ(ty, expected, actual) do { ty ex = expected; if (ex != actual) { printf("Line: %d => \x1b[1;31mTEST FAILED\x1b[0m: %d != %d\n", __LINE__, ex, actual); exit(1); } } while (0);

int main() {
    char test_value = 43;
    char test_value_doubled = test_value * 2;
    ASSERT_EQ(char, root_main(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_array1(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_slice1(test_value), test_value_doubled);
    // ASSERT_EQ(char, root_test_array2(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_slice2(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_array3(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_slice3(test_value), test_value_doubled);

    ASSERT_EQ(char, root_test_record1(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_record2(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_record3(test_value), test_value_doubled);
    ASSERT_EQ(char, root_test_record4(test_value), test_value_doubled);
    // ASSERT_EQ(char, root_test_array4(test_value), test_value_doubled);
    return 0;
}

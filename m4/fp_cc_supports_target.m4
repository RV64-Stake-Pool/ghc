# FP_CC_SUPPORTS_TARGET
# ---------------------
# Does CC support the --target=<triple> option? If so, we should pass it
# whenever possible to avoid ambiguity and potential compile-time errors (e.g.
# see #20162).
#
# The primary effect of this is updating CONF_CC_OPTS_STAGE[12] to
# explicitly ask the compiler to generate code for the $TargetPlatform.
AC_DEFUN([FP_CC_SUPPORTS_TARGET],
[
   AC_REQUIRE([AC_PROG_CC])
   AC_MSG_CHECKING([whether $1 CC supports --target])
   echo 'int main() { return 0; }' > conftest.c
   if $CC --target=$TargetPlatform -Werror -x c /dev/null -dM -E > conftest.txt 2>&1; then
       CONF_CC_SUPPORTS_TARGET=YES
       AC_MSG_RESULT([yes])
   else
       CONF_CC_SUPPORTS_TARGET=NO
       AC_MSG_RESULT([no])
   fi
   rm -f conftest.c conftest.o conftest

   if test $CONF_CC_SUPPORTS_TARGET = YES ; then
       CONF_CC_OPTS_STAGE1="--target=$TargetPlatform $CONF_CC_OPTS_STAGE1"
       CONF_CC_OPTS_STAGE2="--target=$TargetPlatform $CONF_CC_OPTS_STAGE2"
   fi
])


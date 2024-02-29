#include "llvm_wrap.h"

#include <llvm-c/Target.h>

void LLVM_InitializeAllTargetInfos(void) {
    LLVMInitializeAllTargetInfos();
}

void LLVM_InitializeAllTargets(void) {
    LLVMInitializeAllTargets();
}

void LLVM_InitializeAllTargetMCs(void) {
    LLVMInitializeAllTargetMCs();
}

void LLVM_InitializeAllAsmPrinters(void) {
    LLVMInitializeAllAsmPrinters();
}

void LLVM_InitializeAllAsmParsers(void) {
    LLVMInitializeAllAsmParsers();
}

void LLVM_InitializeAllDisassemblers(void) {
    LLVMInitializeAllDisassemblers();
}

/* These functions return true on failure. */
LLVMBool LLVM_InitializeNativeTarget(void) {
    return LLVMInitializeNativeTarget();
}

LLVMBool LLVM_InitializeNativeAsmParser(void) {
    return LLVMInitializeNativeAsmParser();
}

LLVMBool LLVM_InitializeNativeAsmPrinter(void) {
    return LLVMInitializeNativeAsmPrinter();
}

LLVMBool LLVM_InitializeNativeDisassembler(void) {
    return LLVMInitializeNativeDisassembler();
}



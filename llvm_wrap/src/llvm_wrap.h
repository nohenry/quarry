#pragma once

#include <llvm-c/Core.h>

#ifdef __cplusplus
extern "C" {
#endif

void LLVM_InitializeAllTargetInfos(void); 
void LLVM_InitializeAllTargets(void); 
void LLVM_InitializeAllTargetMCs(void); 
void LLVM_InitializeAllAsmPrinters(void);
void LLVM_InitializeAllAsmParsers(void); 
void LLVM_InitializeAllDisassemblers(void); 

/* These functions return true on failure. */
LLVMBool LLVM_InitializeNativeTarget(void); 
LLVMBool LLVM_InitializeNativeAsmParser(void); 
LLVMBool LLVM_InitializeNativeAsmPrinter(void);
LLVMBool LLVM_InitializeNativeDisassembler(void);

#ifdef __cplusplus
}
#endif

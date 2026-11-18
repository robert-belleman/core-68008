#include <stdio.h>
#include "m68k.h"
unsigned int m68k_read_disassembler_8(unsigned int a){return 0;}
unsigned int m68k_read_disassembler_16(unsigned int a){return 0;}
unsigned int m68k_read_disassembler_32(unsigned int a){return 0;}
unsigned int m68k_read_memory_8(unsigned int a){return 0;}
unsigned int m68k_read_memory_16(unsigned int a){return 0;}
unsigned int m68k_read_memory_32(unsigned int a){return 0;}
int main(){for(unsigned i=0;i<65536;i++)putchar(m68k_is_valid_instruction(i,M68K_CPU_TYPE_68000)?'1':'0');return 0;}

// Remplacement de fonctions C importées (même principe que fishhook, de Facebook) : on réécrit les pointeurs
// des tables d'import (__got, __la_symbol_ptr) de chaque image chargée. Aucune modification du code exécutable,
// donc pas besoin de JIT dans LiveContainer.
#include "SMRebind.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>

static SMRebinding *gRebindings;
static size_t gCount;
static const struct mach_header *gSelf;

static void SMMakeWritable(void *addr, size_t size) {
    uintptr_t page = (uintptr_t)addr & ~((uintptr_t)PAGE_SIZE - 1);
    size_t len = ((uintptr_t)addr + size) - page;
    if (mprotect((void *)page, len, PROT_READ | PROT_WRITE) != 0) {
        vm_protect(mach_task_self(), (vm_address_t)page, len, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    }
}

static void SMPerform(const struct section_64 *section, intptr_t slide, struct nlist_64 *symtab, char *strtab, uint32_t *indirect) {
    uint32_t *indices = indirect + section->reserved1;
    void **bindings = (void **)((uintptr_t)slide + section->addr);
    size_t n = section->size / sizeof(void *);
    for (size_t i = 0; i < n; i++) {
        uint32_t idx = indices[i];
        if (idx == INDIRECT_SYMBOL_ABS || idx == INDIRECT_SYMBOL_LOCAL || idx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[idx].n_un.n_strx;
        if (strlen(name) < 2) continue;
        for (size_t j = 0; j < gCount; j++) {
            if (strcmp(name + 1, gRebindings[j].name) != 0) continue;
            if (bindings[i] == gRebindings[j].replacement) break;
            SMMakeWritable(&bindings[i], sizeof(void *));
            bindings[i] = gRebindings[j].replacement;
            break;
        }
    }
}

static void SMRebindImage(const struct mach_header *header, intptr_t slide) {
    if (header == gSelf || header->magic != MH_MAGIC_64) return;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtabCmd = NULL;
    const struct dysymtab_command *dysymtabCmd = NULL;
    uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const struct segment_command_64 *)lc;
        else if (lc->cmd == LC_SYMTAB) symtabCmd = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtabCmd = (const struct dysymtab_command *)lc;
        cur += lc->cmdsize;
    }
    if (!linkedit || !symtabCmd || !dysymtabCmd || !dysymtabCmd->nindirectsyms) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    struct nlist_64 *symtab = (struct nlist_64 *)(base + symtabCmd->symoff);
    char *strtab = (char *)(base + symtabCmd->stroff);
    uint32_t *indirect = (uint32_t *)(base + dysymtabCmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        cur += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, SEG_DATA) != 0 && strcmp(seg->segname, "__DATA_CONST") != 0 && strcmp(seg->segname, "__AUTH_CONST") != 0) continue;
        const struct section_64 *sections = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++) {
            uint32_t type = sections[s].flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                SMPerform(&sections[s], slide, symtab, strtab, indirect);
        }
    }
}

static void SMAddImage(const struct mach_header *header, intptr_t slide) {
    SMRebindImage(header, slide);
}

void SMRebindSymbols(SMRebinding *rebindings, size_t count) {
    Dl_info info;
    if (dladdr((const void *)&SMRebindSymbols, &info)) gSelf = (const struct mach_header *)info.dli_fbase;
    gRebindings = malloc(sizeof(SMRebinding) * count);
    memcpy(gRebindings, rebindings, sizeof(SMRebinding) * count);
    gCount = count;
    // Appelé pour chaque image déjà chargée, puis pour chaque nouvelle
    _dyld_register_func_for_add_image(SMAddImage);
}

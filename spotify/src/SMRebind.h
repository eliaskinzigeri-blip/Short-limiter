#pragma once
#include <stddef.h>

typedef struct {
    const char *name;   // nom C de la fonction (sans le « _ » initial)
    void *replacement;
} SMRebinding;

/// Redirige les appels aux fonctions données, dans toutes les images chargées (sauf ce tweak).
void SMRebindSymbols(SMRebinding *rebindings, size_t count);

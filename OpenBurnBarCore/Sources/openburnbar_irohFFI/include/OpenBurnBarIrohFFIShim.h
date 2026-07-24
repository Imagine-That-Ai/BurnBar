#pragma once

// The UniFFI generator owns the canonical declarations. This stable shim lets
// SwiftPM expose them as a Linux Clang module without duplicating generated code.
#include "../../OpenBurnBarIroh/Generated/openburnbar_irohFFI.h"

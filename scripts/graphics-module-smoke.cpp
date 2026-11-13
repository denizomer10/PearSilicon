#include "../runtime/include/PearRuntimeModules.h"
#include <cassert>
#include <cstdlib>
int main(int argc, char **argv) {
    assert(argc == 4);
    assert(PearRuntimeModuleEnabled("graphics") == atoi(argv[1]));
    assert(PearRuntimeModuleEnabled("graphics-gl") == atoi(argv[2]));
    assert(PearRuntimeModuleEnabled("graphics-metal") == atoi(argv[3]));
    assert(PearRuntimeModuleEnabled("core"));
}

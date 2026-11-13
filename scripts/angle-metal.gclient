solutions = [{
  'name': '.',
  'url': 'https://github.com/denizomer10/angle.git',
  'managed': False,
  'custom_vars': {
    'checkout_angle_dawn_deps': False,
    'checkout_angle_cl_deps': False,
    'checkout_angle_mesa': False,
    'checkout_angle_restricted_traces': False,
  },
  'custom_deps': {
    # Testing's GN metadata is initialized at its pinned gitlink separately.
    'testing': None,
    'third_party/SwiftShader': None,
    'third_party/VK-GL-CTS/src': None,
    'third_party/glslang/src': None,
    'third_party/lunarg-vulkantools/src': None,
    'third_party/spirv-cross/src': None,
    'third_party/spirv-headers/src': None,
    'third_party/spirv-tools/src': None,
    'third_party/vulkan-headers/src': None,
    'third_party/vulkan-loader/src': None,
    'third_party/vulkan-tools/src': None,
    'third_party/vulkan-utility-libraries/src': None,
    'third_party/vulkan-validation-layers/src': None,
    'third_party/vulkan_memory_allocator': None,
    'third_party/catapult': None,
  },
}]
target_os = []

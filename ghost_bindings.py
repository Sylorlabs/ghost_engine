import ctypes
import os
import sys

# Locate the compiled shared library
# Zig builds libraries in zig-out/lib/ by default.
lib_ext = ".so"
if sys.platform == "darwin":
    lib_ext = ".dylib"
elif sys.platform == "win32":
    lib_ext = ".dll"

# The shared library will be placed in zig-out/lib/libghost.so
lib_path = os.path.join(os.path.dirname(__file__), "zig-out", "lib", f"libghost{lib_ext}")

try:
    ghost_lib = ctypes.CDLL(lib_path)
except OSError as e:
    raise RuntimeError(f"Failed to load Ghost Engine C-ABI from {lib_path}. Did you run 'zig build phase13-bridge'?") from e

# export fn ghost_ingest_intent(intent_ptr: [*]const u8, intent_len: usize) [*]u8
ghost_lib.ghost_ingest_intent.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
ghost_lib.ghost_ingest_intent.restype = ctypes.POINTER(ctypes.c_char)

# export fn ghost_free_string(ptr: [*]u8) void
ghost_lib.ghost_free_string.argtypes = [ctypes.POINTER(ctypes.c_char)]
ghost_lib.ghost_free_string.restype = None

def ingest_intent(intent: str) -> str:
    """
    Sends a string intent to the Ghost Engine matrix via zero-copy C-ABI.
    Returns the string response and frees the allocated memory safely.
    """
    intent_bytes = intent.encode('utf-8')
    intent_len = len(intent_bytes)
    
    # Send to Zig (zero-copy memory transfer)
    response_ptr = ghost_lib.ghost_ingest_intent(intent_bytes, intent_len)
    
    if not response_ptr:
        raise RuntimeError("Ghost Engine returned a null pointer.")
        
    # Read the null-terminated string back from the raw pointer
    response_bytes = ctypes.cast(response_ptr, ctypes.c_char_p).value
    response_str = response_bytes.decode('utf-8')
    
    # Explicitly return the memory to the Zig allocator
    ghost_lib.ghost_free_string(response_ptr)
    
    return response_str

# export fn ghost_synthesize_samples(a_ptr, b_ptr, exp_ptr, len) [*]u8
ghost_lib.ghost_synthesize_samples.argtypes = [
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t
]
ghost_lib.ghost_synthesize_samples.restype = ctypes.POINTER(ctypes.c_char)

def synthesize_from_samples(a_list: list[int], b_list: list[int], expected_list: list[int]) -> str:
    """
    Feeds a set of numeric samples to the Ghost Engine to synthesize an SMT formula.
    """
    length = len(a_list)
    assert len(b_list) == length and len(expected_list) == length, "Sample lists must be same length"
    
    # Create C arrays
    c_uint64_array = ctypes.c_uint64 * length
    a_arr = c_uint64_array(*a_list)
    b_arr = c_uint64_array(*b_list)
    exp_arr = c_uint64_array(*expected_list)
    
    # Call Zig C-ABI
    response_ptr = ghost_lib.ghost_synthesize_samples(a_arr, b_arr, exp_arr, length)
    
    if not response_ptr:
        raise RuntimeError("Ghost Engine returned a null pointer.")
        
    response_bytes = ctypes.cast(response_ptr, ctypes.c_char_p).value
    response_str = response_bytes.decode('utf-8')
    
    ghost_lib.ghost_free_string(response_ptr)
    return response_str

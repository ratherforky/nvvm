{-# LANGUAGE BangPatterns             #-}
{-# LANGUAGE CPP                      #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MagicHash                #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE UnboxedTuples            #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
--------------------------------------------------------------------------------
-- |
-- Module    : Foreign.NVVM.Compile
-- Copyright : [2016..2023] Trevor L. McDonell
-- License   : BSD
--
-- Program compilation
--
--------------------------------------------------------------------------------

module Foreign.NVVM.Compile (

  Program,
  Result(..),
  CompileOption(..),

  compileModule, compileModules,

  create,
  destroy,
  addModule,     addModuleFromPtr,
  addModuleLazy, addModuleLazyFromPtr,
  compile,
  verify

) where

import Foreign.CUDA.Analysis
import Foreign.NVVM.Error
import Foreign.NVVM.Internal.C2HS

import Foreign.C
import Foreign.Marshal
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Storable

import Control.Exception
import Data.Word
import Text.Printf
import Data.ByteString                                              ( ByteString )
import Data.ByteString.Short                                        ( ShortByteString )
import qualified Data.ByteString.Char8                              as B
import qualified Data.ByteString.Unsafe                             as B
import qualified Data.ByteString.Internal                           as B
import qualified Data.ByteString.Short                              as BS
import qualified Data.ByteString.Short.Internal                     as BI

import GHC.Exts
import GHC.Base                                                     ( IO(..) )


#include "cbits/stubs.h"
{# context lib="nvvm" #}


-- | An NVVM program
--
newtype Program = Program { useProgram :: {# type nvvmProgram #} }
  deriving ( Eq, Show )

-- | The result of compiling an NVVM program.
--
data Result = Result
  { compileResult :: !ByteString  -- ^ The compiled kernel, which can be loaded into the current program using 'Foreign.CUDA.Driver.loadData*'
  , compileLog    :: !ByteString  -- ^ Warning messages generated by the compiler/verifier
  }

-- | Program compilation options
--
data CompileOption
  = OptimisationLevel !Int        -- ^ optimisation level, from 0 (disable optimisations) to 3 (default)
  | Target !Compute               -- ^ target architecture to compile for (default: compute 2.0)
  | FlushToZero                   -- ^ flush denormal values to zero when performing single-precision floating-point operations (default: no)
  | NoFMA                         -- ^ disable fused-multiply-add instructions (default: enabled)
  | FastSqrt                      -- ^ use a fast approximation for single-precision floating-point square root (default: no)
  | FastDiv                       -- ^ use a fast approximation for single-precision floating-point division and reciprocal (default: no)
  | GenerateDebugInfo             -- ^ generate debugging information (-g) (default: no)
  deriving ( Eq, Show )


-- | Compile an NVVM IR module, in either bitcode or textual representation,
-- into PTX code.
--
{-# INLINEABLE compileModule #-}
compileModule
    :: ShortByteString            -- ^ name of the module
    -> ByteString                 -- ^ NVVM IR in either textual or bitcode representation
    -> [CompileOption]            -- ^ compiler options
    -> IO Result
compileModule !name !bs !opts =
  compileModules [(name,bs)] opts


-- | Compile a collection of NVVM IR modules into PTX code
--
{-# INLINEABLE compileModules #-}
compileModules
    :: [(ShortByteString, ByteString)]  -- ^ (module name, module NVVM IR) pairs to compile
    -> [CompileOption]                  -- ^ compiler options
    -> IO Result
compileModules !bss !opts =
  bracket create destroy $ \prg -> do
    mapM_ (uncurry (addModule prg)) bss
    (messages, result) <- compile prg opts
    case result of
      Nothing  -> nvvmErrorIO (B.unpack messages)
      Just ptx -> return $ Result ptx messages


-- | Create an empty 'Program'
--
-- <http://docs.nvidia.com/cuda/libnvvm-api/group__compilation.html#group__compilation_1g46a0ab04a063cba28bfbb41a1939e3f4>
--
{-# INLINEABLE create #-}
{# fun unsafe nvvmCreateProgram as create
    { alloca- `Program' peekProgram*
    }
    -> `()' checkStatus*-
#}


-- | Destroy a 'Program'
--
-- <http://docs.nvidia.com/cuda/libnvvm-api/group__compilation.html#group__compilation_1gfba94cab1224c0152841b80690d366aa>
--
{-# INLINEABLE destroy #-}
{#
  fun unsafe nvvmDestroyProgram as destroy
    { withProgram* `Program'
    }
    -> `()' checkStatus*-
#}


-- | Add a module level NVVM IR to a program
--
-- <http://docs.nvidia.com/cuda/libnvvm-api/group__compilation.html#group__compilation_1g0c22d2b9be033c165bc37b16f3ed75c6>
--
{-# INLINEABLE addModule #-}
addModule
    :: Program              -- ^ NVVM program to add to
    -> ShortByteString      -- ^ Name of the module (defaults to \"@\<unnamed\>@\" if empty)
    -> ByteString           -- ^ NVVM IR module in either bitcode or textual representation
    -> IO ()
addModule !prg !name !bs =
  B.unsafeUseAsCStringLen bs $ \(ptr,len) ->
  addModuleFromPtr prg name len (castPtr ptr)


-- | As with 'addModule', but read the specified number of bytes from the given
-- pointer.
--
{-# INLINEABLE addModuleFromPtr #-}
addModuleFromPtr
    :: Program              -- ^ NVVM program to add to
    -> ShortByteString      -- ^ Name of the module (defaults to \"@\<unnamed\>@\" if empty)
    -> Int                  -- ^ Number of bytes in the module
    -> Ptr Word8            -- ^ NVVM IR module in bitcode or textual representation
    -> IO ()
addModuleFromPtr !prg !name !size !buffer =
  nvvmAddModuleToProgram prg buffer size name
  where
    {#
      fun unsafe nvvmAddModuleToProgram
        { useProgram    `Program'
        , castPtr       `Ptr Word8'
        , cIntConv      `Int'
        , useAsCString* `ShortByteString'
        }
        -> `()' checkStatus*-
    #}


-- | Add a module level NVVM IR to a program.
--
-- The module is loaded lazily: only symbols required by modules loaded using
-- 'addModule' or 'addModuleFromPtr' will be loaded.
--
-- Requires CUDA-10.0
--
-- <https://docs.nvidia.com/cuda/libnvvm-api/group__compilation.html#group__compilation_1g5356ce5063db232cd4330b666c62219b>
--
-- @since 0.9.0.0
--
{-# INLINEABLE addModuleLazy #-}
addModuleLazy
    :: Program              -- ^ NVVM program to add to
    -> ShortByteString      -- ^ Name of the module (defaults to \"@\<unnamed\>@\" if empty)
    -> ByteString           -- ^ NVVM IR module in either bitcode or textual representation
    -> IO ()
#if CUDA_VERSION < 10000
addModuleLazy = requireSDK 'addModuleLazy 10.0
#else
addModuleLazy !prg !name !bs =
  B.unsafeUseAsCStringLen bs $ \(buffer, size) ->
  addModuleLazyFromPtr prg name size (castPtr buffer)
#endif


-- | As with 'addModuleLazy', but read the specified number of bytes from the
-- given pointer (the symbols are loaded lazily, the data in the buffer will be
-- read immediately).
--
-- Requires CUDA-10.0
--
-- @since 0.9.0.0
--
{-# INLINEABLE addModuleLazyFromPtr #-}
addModuleLazyFromPtr
    :: Program              -- ^ NVVM program to add to
    -> ShortByteString      -- ^ Name of the module (defaults to \"@\<unnamed\>@\" if empty)
    -> Int                  -- ^ Number of bytes in the module
    -> Ptr Word8            -- ^ NVVM IR in bitcode or textual representation
    -> IO ()
#if CUDA_VERSION < 10000
addModuleLazyFromPtr = requireSDK 'addModuleLazyFromPtr 10.0
#else
addModuleLazyFromPtr !prg !name !size !buffer =
  nvvmLazyAddModuleToProgram prg buffer size name
  where
    {#
      fun unsafe nvvmLazyAddModuleToProgram
        { useProgram    `Program'
        , castPtr       `Ptr Word8'
        , cIntConv      `Int'
        , useAsCString* `ShortByteString'
        }
        -> `()' checkStatus*-
    #}
#endif


-- | Compile the NVVM program. Returns the log from the compiler/verifier and,
-- if successful, the compiled program.
--
-- <http://docs.nvidia.com/cuda/libnvvm-api/group__compilation.html#group__compilation_1g76ac1e23f5d0e2240e78be0e63450346>
--
{-# INLINEABLE compile #-}
compile :: Program -> [CompileOption] -> IO (ByteString, Maybe ByteString)
compile !prg !opts = do
  status    <- withCompileOptions opts (nvvmCompileProgram prg)
  messages  <- retrieve (nvvmGetProgramLogSize prg) (nvvmGetProgramLog prg)
  case status of
    Success -> do ptx <- retrieve (nvvmGetCompiledResultSize prg) (nvvmGetCompiledResult prg)
                  return (messages, Just ptx)
    _       ->    return (messages, Nothing)
  where
    {# fun unsafe nvvmCompileProgram
        { useProgram `Program'
        , cIntConv   `Int'
        , id         `Ptr CString'
        }
        -> `Status' cToEnum
    #}

    {# fun unsafe nvvmGetCompiledResultSize
        { useProgram `Program'
        , alloca-    `Int'     peekIntConv*
        }
        -> `()' checkStatus*-
    #}

    {# fun unsafe nvvmGetCompiledResult
        { useProgram       `Program'
        , withForeignPtr'* `ForeignPtr Word8'
        }
        -> `()' checkStatus*-
    #}


-- | Verify the NVVM program. Returns whether compilation will succeed, together
-- with any error or warning messages.
--
{-# INLINEABLE verify #-}
verify :: Program -> [CompileOption] -> IO (Status, ByteString)
verify !prg !opts = do
  status   <- withCompileOptions opts (nvvmVerifyProgram prg)
  messages <- retrieve (nvvmGetProgramLogSize prg) (nvvmGetProgramLog prg)
  return (status, messages)
  where
    {#
      fun unsafe nvvmVerifyProgram
        { useProgram `Program'
        , cIntConv   `Int'
        , id         `Ptr CString'
        }
        -> `Status' cToEnum
    #}


{# fun unsafe nvvmGetProgramLogSize
    { useProgram `Program'
    , alloca-    `Int'     peekIntConv*
    }
    -> `()' checkStatus*-
#}

{# fun unsafe nvvmGetProgramLog
    { useProgram       `Program'
    , withForeignPtr'* `ForeignPtr Word8'
    }
    -> `()' checkStatus*-
#}


-- Utilities
-- ---------

{-# INLINEABLE withForeignPtr' #-}
withForeignPtr' :: ForeignPtr Word8 -> (Ptr CChar -> IO a) -> IO a
withForeignPtr' fp f = withForeignPtr fp (f . castPtr)


{-# INLINEABLE withCompileOptions #-}
withCompileOptions :: [CompileOption] -> (Int -> Ptr CString -> IO a) -> IO a
withCompileOptions opts next =
  withMany withCString (map toStr opts) $ \cs -> withArrayLen cs next
  where
    toStr :: CompileOption -> String
    toStr (OptimisationLevel n)  = printf "-opt=%d" n
    toStr (Target (Compute n m)) = printf "-arch=compute_%d%d" n m
    toStr FlushToZero            = "-ftz=1"
    toStr NoFMA                  = "-fma=0"
    toStr FastSqrt               = "-prec-sqrt=0"
    toStr FastDiv                = "-prec-div=0"
    toStr GenerateDebugInfo      = "-g"

{-# INLINEABLE retrieve #-}
retrieve :: IO Int -> (ForeignPtr Word8 -> IO ()) -> IO ByteString
retrieve size fill = do
  bytes <- size
  if bytes <= 1             -- size includes NULL terminator
    then return B.empty
    else do fp <- mallocForeignPtrBytes bytes
            _  <- fill fp
            return (B.fromForeignPtr fp 0 bytes)

{-# INLINEABLE peekProgram #-}
peekProgram :: Ptr {# type nvvmProgram #} -> IO Program
peekProgram p = Program `fmap` peek p

{-# INLINEABLE withProgram #-}
withProgram :: Program -> (Ptr {# type nvvmProgram #} -> IO a) -> IO a
withProgram p = with (useProgram p)


-- [Short]ByteStrings are not null-terminated, so can't be passed directly to C.
--
-- unsafeUseAsCString :: ShortByteString -> CString
-- unsafeUseAsCString (BI.SBS ba#) = Ptr (byteArrayContents# ba#)

{-# INLINE useAsCString #-}
useAsCString :: ShortByteString -> (CString -> IO a) -> IO a
useAsCString (BI.SBS ba#) action = IO $ \s0 ->
  case sizeofByteArray# ba#                              of { n# ->
  case newPinnedByteArray# (n# +# 1#) s0                 of { (# s1, mba# #) ->
  case byteArrayContents# (unsafeCoerce# mba#)           of { addr# ->
  case copyByteArrayToAddr# ba# 0# addr# n# s1           of { s2 ->
  case writeWord8OffAddr# addr# n# (wordToWord8# 0##) s2 of { s3 ->
  case action (Ptr addr#)                                of { IO action' ->
  case action' s3                                        of { (# s4, r  #) ->
  case touch# mba# s4                                    of { s5 ->
  (# s5, r #)
 }}}}}}}}

#if __GLASGOW_HASKELL__ < 902
{-# INLINE wordToWord8# #-}
wordToWord8# :: Word# -> Word#
wordToWord8# x = x
#endif


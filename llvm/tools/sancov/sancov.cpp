//===-- sancov.cpp --------------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
// This file is a command-line tool for reading and analyzing sanitizer
// coverage.
//===----------------------------------------------------------------------===//
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/Twine.h"
#include "llvm/DebugInfo/DWARF/DWARFCompileUnit.h"
#include "llvm/DebugInfo/DWARF/DWARFContext.h"
#include "llvm/DebugInfo/DWARF/DWARFDie.h"
#include "llvm/DebugInfo/DWARF/DWARFFormValue.h"
#include "llvm/DebugInfo/Symbolize/SymbolizableModule.h"
#include "llvm/DebugInfo/Symbolize/Symbolize.h"
#include "llvm/Demangle/Demangle.h"
#include "llvm/MC/MCAsmInfo.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCDisassembler/MCDisassembler.h"
#include "llvm/MC/MCInst.h"
#include "llvm/MC/MCInstrAnalysis.h"
#include "llvm/MC/MCInstrInfo.h"
#include "llvm/MC/MCObjectFileInfo.h"
#include "llvm/MC/MCRegisterInfo.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/MCTargetOptions.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Object/Archive.h"
#include "llvm/Object/Binary.h"
#include "llvm/Object/COFF.h"
#include "llvm/Object/ELFObjectFile.h"
#include "llvm/Object/MachO.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Object/XCOFFObjectFile.h"
#include "llvm/Option/ArgList.h"
#include "llvm/Option/Option.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Driver.h"
#include "llvm/Support/Errc.h"
#include "llvm/Support/ErrorOr.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/MD5.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Regex.h"
#include "llvm/Support/SHA1.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/SpecialCaseList.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/WithColor.h"
#include "llvm/Support/YAMLParser.h"
#include "llvm/Support/raw_ostream.h"

#include <set>
#include <vector>

using namespace llvm;

namespace {

// Command-line option boilerplate.
namespace {
using namespace llvm::opt;
enum ID {
  OPT_INVALID = 0, // This is not an option ID.
#define OPTION(...) LLVM_MAKE_OPT_ID(__VA_ARGS__),
#include "Opts.inc"
#undef OPTION
};

#define OPTTABLE_CODE
#include "Opts.inc"

class SancovOptTable : public opt::OptTable {
public:
  SancovOptTable() : OptTable(optionTables()) {}
};
} // namespace

// --------- COMMAND LINE FLAGS ---------

enum ActionType {
  CoveredFunctionsAction,
  DiffAction,
  HtmlReportAction,
  MergeAction,
  NotCoveredFunctionsAction,
  PrintAction,
  PrintCovPointsAction,
  PrintDataflowPointsAction,
  StatsAction,
  SymbolizeAction,
  SymbolizeDataflowAction,
  UnionAction
};

static ActionType Action;
static std::vector<std::string> ClInputFiles;
static bool ClDemangle;
static bool ClSkipDeadFiles;
static bool ClUseDefaultIgnorelist;
static std::string ClStripPathPrefix;
static std::string ClIgnorelist;
static std::string ClOutputFile;

static const char *const DefaultIgnorelistStr = "fun:__sanitizer_.*\n"
                                                "src:/usr/include/.*\n"
                                                "src:.*/libc\\+\\+/.*\n";

// --------- FORMAT SPECIFICATION ---------

struct FileHeader {
  uint32_t Bitness;
  uint32_t Magic;
};

static const uint32_t BinCoverageMagic = 0xC0BFFFFF;
static const uint32_t Bitness32 = 0xFFFFFF32;
static const uint32_t Bitness64 = 0xFFFFFF64;

static const Regex SancovFileRegex("(.*)\\.[0-9]+\\.sancov");
static const Regex SymcovFileRegex(".*\\.symcov");

// --------- MAIN DATASTRUCTURES ----------

// Contents of .sancov file: list of coverage point addresses that were
// executed.
struct RawCoverage {
  explicit RawCoverage(std::unique_ptr<std::set<uint64_t>> Addrs,
                       FileHeader Header)
      : Addrs(std::move(Addrs)), Header(Header) {}

  // Read binary .sancov file.
  static ErrorOr<std::unique_ptr<RawCoverage>>
  read(const std::string &FileName);

  // Write binary .sancov file.
  static void write(const std::string &FileName, const RawCoverage &Coverage);

  std::unique_ptr<std::set<uint64_t>> Addrs;
  FileHeader Header;
};

// Coverage point has an opaque Id and corresponds to multiple source locations.
struct CoveragePoint {
  explicit CoveragePoint(const std::string &Id) : Id(Id) {}

  std::string Id;
  SmallVector<DILineInfo, 1> Locs;
};

// Symcov file content: set of covered Ids plus information about all available
// coverage points.
struct SymbolizedCoverage {
  // Read json .symcov file.
  static std::unique_ptr<SymbolizedCoverage> read(const std::string &InputFile);

  std::set<std::string> CoveredIds;
  std::string BinaryHash;
  std::vector<CoveragePoint> Points;
};

struct CoverageStats {
  size_t AllPoints;
  size_t CovPoints;
  size_t AllFns;
  size_t CovFns;
};

// --------- ERROR HANDLING ---------

static void fail(const llvm::Twine &E) {
  errs() << "ERROR: " << E << "\n";
  exit(1);
}

static void failIf(bool B, const llvm::Twine &E) {
  if (B)
    fail(E);
}

static void failIfError(std::error_code Error) {
  if (!Error)
    return;
  errs() << "ERROR: " << Error.message() << "(" << Error.value() << ")\n";
  exit(1);
}

template <typename T> static void failIfError(const ErrorOr<T> &E) {
  failIfError(E.getError());
}

static void failIfError(Error Err) {
  if (Err) {
    logAllUnhandledErrors(std::move(Err), errs(), "ERROR: ");
    exit(1);
  }
}

template <typename T> static void failIfError(Expected<T> &E) {
  failIfError(E.takeError());
}

static void failIfNotEmpty(const llvm::Twine &E) {
  if (E.str().empty())
    return;
  fail(E);
}

template <typename T>
static void failIfEmpty(const std::unique_ptr<T> &Ptr,
                        const std::string &Message) {
  if (Ptr.get())
    return;
  fail(Message);
}

// ----------- Coverage I/O ----------
template <typename T>
static void readInts(const char *Start, const char *End,
                     std::set<uint64_t> *Ints) {
  const T *S = reinterpret_cast<const T *>(Start);
  const T *E = reinterpret_cast<const T *>(End);
  std::copy(S, E, std::inserter(*Ints, Ints->end()));
}

ErrorOr<std::unique_ptr<RawCoverage>>
RawCoverage::read(const std::string &FileName) {
  ErrorOr<std::unique_ptr<MemoryBuffer>> BufOrErr =
      MemoryBuffer::getFile(FileName);
  if (!BufOrErr)
    return BufOrErr.getError();
  std::unique_ptr<MemoryBuffer> Buf = std::move(BufOrErr.get());
  if (Buf->getBufferSize() < 8) {
    errs() << "File too small (<8): " << Buf->getBufferSize() << '\n';
    return make_error_code(errc::illegal_byte_sequence);
  }
  const FileHeader *Header =
      reinterpret_cast<const FileHeader *>(Buf->getBufferStart());

  if (Header->Magic != BinCoverageMagic) {
    errs() << "Wrong magic: " << Header->Magic << '\n';
    return make_error_code(errc::illegal_byte_sequence);
  }

  auto Addrs = std::make_unique<std::set<uint64_t>>();

  switch (Header->Bitness) {
  case Bitness64:
    readInts<uint64_t>(Buf->getBufferStart() + 8, Buf->getBufferEnd(),
                       Addrs.get());
    break;
  case Bitness32:
    readInts<uint32_t>(Buf->getBufferStart() + 8, Buf->getBufferEnd(),
                       Addrs.get());
    break;
  default:
    errs() << "Unsupported bitness: " << Header->Bitness << '\n';
    return make_error_code(errc::illegal_byte_sequence);
  }

  // Ignore slots that are zero, so a runtime implementation is not required
  // to compactify the data.
  Addrs->erase(0);

  return std::make_unique<RawCoverage>(std::move(Addrs), *Header);
}

// Print coverage addresses.
raw_ostream &operator<<(raw_ostream &OS, const RawCoverage &CoverageData) {
  for (auto Addr : *CoverageData.Addrs) {
    OS << "0x";
    OS.write_hex(Addr);
    OS << "\n";
  }
  return OS;
}

// Write coverage addresses in binary format.
void RawCoverage::write(const std::string &FileName,
                        const RawCoverage &Coverage) {
  std::error_code EC;
  raw_fd_ostream OS(FileName, EC, sys::fs::OF_None);
  failIfError(EC);

  OS.write(reinterpret_cast<const char *>(&Coverage.Header),
           sizeof(Coverage.Header));

  switch (Coverage.Header.Bitness) {
  case Bitness64:
    for (auto Addr : *Coverage.Addrs) {
      uint64_t Addr64 = Addr;
      OS.write(reinterpret_cast<const char *>(&Addr64), sizeof(Addr64));
    }
    break;
  case Bitness32:
    for (auto Addr : *Coverage.Addrs) {
      uint32_t Addr32 = static_cast<uint32_t>(Addr);
      OS.write(reinterpret_cast<const char *>(&Addr32), sizeof(Addr32));
    }
    break;
  default:
    fail("Unsupported bitness: " + std::to_string(Coverage.Header.Bitness));
  }
}

static raw_ostream &operator<<(raw_ostream &OS, const CoverageStats &Stats) {
  OS << "all-edges: " << Stats.AllPoints << "\n";
  OS << "cov-edges: " << Stats.CovPoints << "\n";
  OS << "all-functions: " << Stats.AllFns << "\n";
  OS << "cov-functions: " << Stats.CovFns << "\n";
  return OS;
}

// Output symbolized information for coverage points in JSON.
// Format:
// {
//   '<file_name>' : {
//     '<function_name>' : {
//       '<point_id'> : '<line_number>:'<column_number'.
//          ....
//       }
//    }
// }
static void operator<<(json::OStream &W,
                       const std::vector<CoveragePoint> &Points) {
  // Group points by file.
  std::map<std::string, std::vector<const CoveragePoint *>> PointsByFile;
  for (const auto &Point : Points) {
    for (const DILineInfo &Loc : Point.Locs) {
      PointsByFile[Loc.FileName].push_back(&Point);
    }
  }

  for (const auto &P : PointsByFile) {
    std::string FileName = P.first;
    std::map<std::string, std::vector<const CoveragePoint *>> PointsByFn;
    for (auto PointPtr : P.second) {
      for (const DILineInfo &Loc : PointPtr->Locs) {
        PointsByFn[Loc.FunctionName].push_back(PointPtr);
      }
    }

    W.attributeObject(P.first, [&] {
      // Group points by function.
      for (const auto &P : PointsByFn) {
        std::string FunctionName = P.first;
        std::set<std::string> WrittenIds;

        W.attributeObject(FunctionName, [&] {
          for (const CoveragePoint *Point : P.second) {
            for (const auto &Loc : Point->Locs) {
              if (Loc.FileName != FileName || Loc.FunctionName != FunctionName)
                continue;
              if (!WrittenIds.insert(Point->Id).second)
                continue;

              // Output <point_id> : "<line>:<col>".
              W.attribute(Point->Id,
                          (utostr(Loc.Line) + ":" + utostr(Loc.Column)));
            }
          }
        });
      }
    });
  }
}

static void operator<<(json::OStream &W, const SymbolizedCoverage &C) {
  W.object([&] {
    W.attributeArray("covered-points", [&] {
      for (const std::string &P : C.CoveredIds) {
        W.value(P);
      }
    });
    W.attribute("binary-hash", C.BinaryHash);
    W.attributeObject("point-symbol-info", [&] { W << C.Points; });
  });
}

static std::string parseScalarString(yaml::Node *N) {
  SmallString<64> StringStorage;
  yaml::ScalarNode *S = dyn_cast_if_present<yaml::ScalarNode>(N);
  failIf(!S, "expected string");
  return std::string(S->getValue(StringStorage));
}

std::unique_ptr<SymbolizedCoverage>
SymbolizedCoverage::read(const std::string &InputFile) {
  auto Coverage(std::make_unique<SymbolizedCoverage>());

  std::map<std::string, CoveragePoint> Points;
  ErrorOr<std::unique_ptr<MemoryBuffer>> BufOrErr =
      MemoryBuffer::getFile(InputFile);
  failIfError(BufOrErr);

  SourceMgr SM;
  yaml::Stream S(**BufOrErr, SM);

  yaml::document_iterator DI = S.begin();
  failIf(DI == S.end(), "empty document: " + InputFile);
  yaml::Node *Root = DI->getRoot();
  failIf(!Root, "expecting root node: " + InputFile);
  yaml::MappingNode *Top = dyn_cast<yaml::MappingNode>(Root);
  failIf(!Top, "expecting mapping node: " + InputFile);

  for (auto &KVNode : *Top) {
    auto Key = parseScalarString(KVNode.getKey());

    if (Key == "covered-points") {
      yaml::SequenceNode *Points =
          dyn_cast_if_present<yaml::SequenceNode>(KVNode.getValue());
      failIf(!Points, "expected array: " + InputFile);

      for (auto I = Points->begin(), E = Points->end(); I != E; ++I) {
        Coverage->CoveredIds.insert(parseScalarString(&*I));
      }
    } else if (Key == "binary-hash") {
      Coverage->BinaryHash = parseScalarString(KVNode.getValue());
    } else if (Key == "point-symbol-info") {
      yaml::MappingNode *PointSymbolInfo =
          dyn_cast_if_present<yaml::MappingNode>(KVNode.getValue());
      failIf(!PointSymbolInfo, "expected mapping node: " + InputFile);

      for (auto &FileKVNode : *PointSymbolInfo) {
        auto Filename = parseScalarString(FileKVNode.getKey());

        yaml::MappingNode *FileInfo =
            dyn_cast_if_present<yaml::MappingNode>(FileKVNode.getValue());
        failIf(!FileInfo, "expected mapping node: " + InputFile);

        for (auto &FunctionKVNode : *FileInfo) {
          auto FunctionName = parseScalarString(FunctionKVNode.getKey());

          yaml::MappingNode *FunctionInfo =
              dyn_cast_if_present<yaml::MappingNode>(FunctionKVNode.getValue());
          failIf(!FunctionInfo, "expected mapping node: " + InputFile);

          for (auto &PointKVNode : *FunctionInfo) {
            auto PointId = parseScalarString(PointKVNode.getKey());
            auto Loc = parseScalarString(PointKVNode.getValue());

            size_t ColonPos = Loc.find(':');
            failIf(ColonPos == std::string::npos, "expected ':': " + InputFile);

            auto LineStr = Loc.substr(0, ColonPos);
            auto ColStr = Loc.substr(ColonPos + 1, Loc.size());

            DILineInfo LineInfo;
            LineInfo.FileName = Filename;
            LineInfo.FunctionName = FunctionName;
            char *End;
            LineInfo.Line = std::strtoul(LineStr.c_str(), &End, 10);
            LineInfo.Column = std::strtoul(ColStr.c_str(), &End, 10);

            CoveragePoint *CoveragePoint =
                &Points.try_emplace(PointId, PointId).first->second;
            CoveragePoint->Locs.push_back(LineInfo);
          }
        }
      }
    } else {
      errs() << "Ignoring unknown key: " << Key << "\n";
    }
  }

  for (auto &KV : Points) {
    Coverage->Points.push_back(KV.second);
  }

  return Coverage;
}

// ---------- MAIN FUNCTIONALITY ----------

std::string stripPathPrefix(std::string Path) {
  if (ClStripPathPrefix.empty())
    return Path;
  size_t Pos = Path.find(ClStripPathPrefix);
  if (Pos == std::string::npos)
    return Path;
  return Path.substr(Pos + ClStripPathPrefix.size());
}

static std::unique_ptr<symbolize::LLVMSymbolizer>
createSymbolizer(bool UseSymbolTable = true) {
  symbolize::LLVMSymbolizer::Options SymbolizerOptions;
  SymbolizerOptions.Demangle = ClDemangle;
  SymbolizerOptions.UseSymbolTable = UseSymbolTable;
  return std::make_unique<symbolize::LLVMSymbolizer>(SymbolizerOptions);
}

static std::string normalizeFilename(const std::string &FileName) {
  SmallString<256> S(FileName);
  sys::path::remove_dots(S, /* remove_dot_dot */ true);
  return stripPathPrefix(sys::path::convert_to_slash(std::string(S)));
}

class Ignorelists {
public:
  Ignorelists()
      : DefaultIgnorelist(createDefaultIgnorelist()),
        UserIgnorelist(createUserIgnorelist()) {}

  bool isIgnorelisted(const DILineInfo &I) {
    if (DefaultIgnorelist &&
        DefaultIgnorelist->inSection("sancov", "fun", I.FunctionName))
      return true;
    if (DefaultIgnorelist &&
        DefaultIgnorelist->inSection("sancov", "src", I.FileName))
      return true;
    if (UserIgnorelist &&
        UserIgnorelist->inSection("sancov", "fun", I.FunctionName))
      return true;
    if (UserIgnorelist &&
        UserIgnorelist->inSection("sancov", "src", I.FileName))
      return true;
    return false;
  }

private:
  static std::unique_ptr<SpecialCaseList> createDefaultIgnorelist() {
    if (!ClUseDefaultIgnorelist)
      return std::unique_ptr<SpecialCaseList>();
    std::unique_ptr<MemoryBuffer> MB =
        MemoryBuffer::getMemBuffer(DefaultIgnorelistStr);
    std::string Error;
    auto Ignorelist = SpecialCaseList::create(MB.get(), Error);
    failIfNotEmpty(Error);
    return Ignorelist;
  }

  static std::unique_ptr<SpecialCaseList> createUserIgnorelist() {
    if (ClIgnorelist.empty())
      return std::unique_ptr<SpecialCaseList>();
    return SpecialCaseList::createOrDie({{ClIgnorelist}},
                                        *vfs::getRealFileSystem());
  }
  std::unique_ptr<SpecialCaseList> DefaultIgnorelist;
  std::unique_ptr<SpecialCaseList> UserIgnorelist;
};

static std::vector<CoveragePoint>
getCoveragePoints(const std::string &ObjectFile,
                  const std::set<uint64_t> &Addrs,
                  const std::set<uint64_t> &CoveredAddrs) {
  std::vector<CoveragePoint> Result;
  auto Symbolizer(createSymbolizer());
  Ignorelists Ig;

  std::set<std::string> CoveredFiles;
  if (ClSkipDeadFiles) {
    for (auto Addr : CoveredAddrs) {
      // TODO: it would be neccessary to set proper section index here.
      // object::SectionedAddress::UndefSection works for only absolute
      // addresses.
      object::SectionedAddress ModuleAddress = {
          Addr, object::SectionedAddress::UndefSection};

      auto LineInfo = Symbolizer->symbolizeCode(ObjectFile, ModuleAddress);
      failIfError(LineInfo);
      CoveredFiles.insert(LineInfo->FileName);
      auto InliningInfo =
          Symbolizer->symbolizeInlinedCode(ObjectFile, ModuleAddress);
      failIfError(InliningInfo);
      for (uint32_t I = 0; I < InliningInfo->getNumberOfFrames(); ++I) {
        auto FrameInfo = InliningInfo->getFrame(I);
        CoveredFiles.insert(FrameInfo.FileName);
      }
    }
  }

  for (auto Addr : Addrs) {
    std::set<DILineInfo> Infos; // deduplicate debug info.

    // TODO: it would be neccessary to set proper section index here.
    // object::SectionedAddress::UndefSection works for only absolute addresses.
    object::SectionedAddress ModuleAddress = {
        Addr, object::SectionedAddress::UndefSection};

    auto LineInfo = Symbolizer->symbolizeCode(ObjectFile, ModuleAddress);
    failIfError(LineInfo);
    if (ClSkipDeadFiles &&
        CoveredFiles.find(LineInfo->FileName) == CoveredFiles.end())
      continue;
    LineInfo->FileName = normalizeFilename(LineInfo->FileName);
    if (Ig.isIgnorelisted(*LineInfo))
      continue;

    auto Id = utohexstr(Addr, true);
    auto Point = CoveragePoint(Id);
    Infos.insert(*LineInfo);
    Point.Locs.push_back(*LineInfo);

    auto InliningInfo =
        Symbolizer->symbolizeInlinedCode(ObjectFile, ModuleAddress);
    failIfError(InliningInfo);
    for (uint32_t I = 0; I < InliningInfo->getNumberOfFrames(); ++I) {
      auto FrameInfo = InliningInfo->getFrame(I);
      if (ClSkipDeadFiles &&
          CoveredFiles.find(FrameInfo.FileName) == CoveredFiles.end())
        continue;
      FrameInfo.FileName = normalizeFilename(FrameInfo.FileName);
      if (Ig.isIgnorelisted(FrameInfo))
        continue;
      if (Infos.insert(FrameInfo).second)
        Point.Locs.push_back(FrameInfo);
    }

    Result.push_back(Point);
  }

  return Result;
}

static bool isCoveragePointSymbol(StringRef Name) {
  return Name == "__sanitizer_cov" || Name == "__sanitizer_cov_with_check" ||
         Name == "__sanitizer_cov_trace_func_enter" ||
         Name == "__sanitizer_cov_trace_pc_guard" ||
         // Mac has '___' prefix
         Name == "___sanitizer_cov" || Name == "___sanitizer_cov_with_check" ||
         Name == "___sanitizer_cov_trace_func_enter" ||
         Name == "___sanitizer_cov_trace_pc_guard" ||
         // Large Aarch64 binaries use thunks
         Name == "__AArch64ADRPThunk___sanitizer_cov" ||
         Name == "__AArch64ADRPThunk___sanitizer_cov_with_check" ||
         Name == "__AArch64ADRPThunk___sanitizer_cov_trace_func_enter" ||
         Name == "__AArch64ADRPThunk___sanitizer_cov_trace_pc_guard";
}

// The two callbacks of -fsanitize-coverage=trace-args,trace-ret. Their call
// sites are not coverage points: one function has a trace-args call per
// parameter and a trace-ret call per return, so they are reported apart. A
// trace-args call whose descriptor says it reports a load or store through a
// pointer argument (-sanitizer-coverage-trace-pointee-access) is an access.
enum class DataflowKind { Args, Ret, Access };

static StringRef getDataflowKindName(DataflowKind Kind) {
  switch (Kind) {
  case DataflowKind::Args:
    return "args";
  case DataflowKind::Ret:
    return "ret";
  case DataflowKind::Access:
    return "access";
  }
  llvm_unreachable("bad dataflow kind");
}

static std::optional<DataflowKind> getDataflowCallbackKind(StringRef Name) {
  // Large Aarch64 binaries use thunks.
  Name.consume_front("__AArch64ADRPThunk_");
  // Mac has '___' prefix.
  if (Name.starts_with("___"))
    Name = Name.drop_front();
  if (Name == "__sanitizer_cov_trace_args")
    return DataflowKind::Args;
  if (Name == "__sanitizer_cov_trace_ret")
    return DataflowKind::Ret;
  return std::nullopt;
}

static bool isDataflowArgsSymbol(StringRef Name) {
  return getDataflowCallbackKind(Name) == DataflowKind::Args;
}

static bool isDataflowRetSymbol(StringRef Name) {
  return getDataflowCallbackKind(Name) == DataflowKind::Ret;
}

using CallbackPredicate = function_ref<bool(StringRef)>;

// Locate the addresses of the callbacks IsCallback accepts inside the stubs
// table on MachO.
static void findMachOIndirectCallbacks(const object::MachOObjectFile &O,
                                       CallbackPredicate IsCallback,
                                       std::set<uint64_t> *Result) {
  MachO::dysymtab_command Dysymtab = O.getDysymtabLoadCommand();
  MachO::symtab_command Symtab = O.getSymtabLoadCommand();

  for (const auto &Load : O.load_commands()) {
    if (Load.C.cmd == MachO::LC_SEGMENT_64) {
      MachO::segment_command_64 Seg = O.getSegment64LoadCommand(Load);
      for (unsigned J = 0; J < Seg.nsects; ++J) {
        MachO::section_64 Sec = O.getSection64(Load, J);

        uint32_t SectionType = Sec.flags & MachO::SECTION_TYPE;
        if (SectionType == MachO::S_SYMBOL_STUBS) {
          uint32_t Stride = Sec.reserved2;
          uint32_t Cnt = Sec.size / Stride;
          uint32_t N = Sec.reserved1;
          for (uint32_t J = 0; J < Cnt && N + J < Dysymtab.nindirectsyms; J++) {
            uint32_t IndirectSymbol =
                O.getIndirectSymbolTableEntry(Dysymtab, N + J);
            uint64_t Addr = Sec.addr + J * Stride;
            if (IndirectSymbol < Symtab.nsyms) {
              object::SymbolRef Symbol = *(O.getSymbolByIndex(IndirectSymbol));
              Expected<StringRef> Name = Symbol.getName();
              failIfError(Name);
              if (IsCallback(Name.get())) {
                Result->insert(Addr);
              }
            }
          }
        }
      }
    }
    if (Load.C.cmd == MachO::LC_SEGMENT) {
      errs() << "ERROR: 32 bit MachO binaries not supported\n";
    }
  }
}

// Locate the addresses of the callbacks IsCallback accepts.
static std::set<uint64_t> findCallbackAddrs(const object::ObjectFile &O,
                                            CallbackPredicate IsCallback) {
  std::set<uint64_t> Result;

  for (const object::SymbolRef &Symbol : O.symbols()) {
    Expected<uint64_t> AddressOrErr = Symbol.getAddress();
    failIfError(AddressOrErr);
    uint64_t Address = AddressOrErr.get();

    Expected<StringRef> NameOrErr = Symbol.getName();
    failIfError(NameOrErr);
    StringRef Name = NameOrErr.get();

    Expected<uint32_t> FlagsOrErr = Symbol.getFlags();
    // TODO: Test this error.
    failIfError(FlagsOrErr);
    uint32_t Flags = FlagsOrErr.get();

    // XCOFF uses "." prefix for function entry point symbols.
    StringRef EffectiveName =
        (isa<object::XCOFFObjectFile>(&O) && Name.starts_with("."))
            ? Name.drop_front(1)
            : Name;
    if (!(Flags & object::BasicSymbolRef::SF_Undefined) &&
        IsCallback(EffectiveName)) {
      Result.insert(Address);
    }
  }

  if (const auto *CO = dyn_cast<object::COFFObjectFile>(&O)) {
    for (const object::ExportDirectoryEntryRef &Export :
         CO->export_directories()) {
      uint32_t RVA;
      failIfError(Export.getExportRVA(RVA));

      StringRef Name;
      failIfError(Export.getSymbolName(Name));

      if (IsCallback(Name))
        Result.insert(CO->getImageBase() + RVA);
    }
  }

  if (const auto *MO = dyn_cast<object::MachOObjectFile>(&O)) {
    findMachOIndirectCallbacks(*MO, IsCallback, &Result);
  }

  return Result;
}

// Locate __sanitizer_cov* function addresses that are used for coverage
// reporting.
static std::set<uint64_t>
findSanitizerCovFunctions(const object::ObjectFile &O) {
  return findCallbackAddrs(O, isCoveragePointSymbol);
}

// Ported from
// compiler-rt/lib/sanitizer_common/sanitizer_stacktrace.h:GetPreviousInstructionPc
// GetPreviousInstructionPc.
static uint64_t getPreviousInstructionPc(uint64_t PC, Triple TheTriple) {
  if (TheTriple.isARM())
    return (PC - 3) & (~1);
  if (TheTriple.isMIPS() || TheTriple.isSPARC())
    return PC - 8;
  if (TheTriple.isRISCV())
    return PC - 2;
  if (TheTriple.isX86() || TheTriple.isSystemZ())
    return PC - 1;
  return PC - 4;
}

// Call Fn(Addr, NextAddr, Target) for every direct call in the text sections
// of O whose target can be evaluated, Addr being the address of the call and
// NextAddr that of the instruction that follows it. Each kind of point steps
// back from NextAddr in its own way.
static void
visitCallSites(const object::ObjectFile &O,
               function_ref<void(uint64_t Addr, uint64_t NextAddr,
                                 uint64_t Target, uint64_t SectionIndex)>
                   Fn) {
  Triple TheTriple("unknown-unknown-unknown");
  TheTriple.setArch(Triple::ArchType(O.getArch()));
  auto TripleName = TheTriple.getTriple();

  std::string Error;
  const Target *TheTarget = TargetRegistry::lookupTarget(TheTriple, Error);
  failIfNotEmpty(Error);

  std::unique_ptr<const MCSubtargetInfo> STI(
      TheTarget->createMCSubtargetInfo(TheTriple, "", ""));
  failIfEmpty(STI, "no subtarget info for target " + TripleName);

  std::unique_ptr<const MCRegisterInfo> MRI(
      TheTarget->createMCRegInfo(TheTriple));
  failIfEmpty(MRI, "no register info for target " + TripleName);

  MCTargetOptions MCOptions;
  std::unique_ptr<const MCAsmInfo> AsmInfo(
      TheTarget->createMCAsmInfo(*MRI, TheTriple, MCOptions));
  failIfEmpty(AsmInfo, "no asm info for target " + TripleName);

  MCContext Ctx(TheTriple, *AsmInfo, *MRI, *STI);
  std::unique_ptr<MCDisassembler> DisAsm(
      TheTarget->createMCDisassembler(*STI, Ctx));
  failIfEmpty(DisAsm, "no disassembler info for target " + TripleName);

  std::unique_ptr<const MCInstrInfo> MII(TheTarget->createMCInstrInfo());
  failIfEmpty(MII, "no instruction info for target " + TripleName);

  std::unique_ptr<MCInstrAnalysis> MIA(
      TheTarget->createMCInstrAnalysis(MII.get()));
  failIfEmpty(MIA, "no instruction analysis info for target " + TripleName);

  for (object::SectionRef Section : O.sections()) {
    if (Section.isVirtual() || !Section.isText()) // llvm-objdump does the same.
      continue;
    uint64_t SectionAddr = Section.getAddress();
    uint64_t SectSize = Section.getSize();
    if (!SectSize)
      continue;

    Expected<StringRef> BytesStr = Section.getContents();
    failIfError(BytesStr);
    ArrayRef<uint8_t> Bytes = arrayRefFromStringRef(*BytesStr);

    if (MIA)
      MIA->resetState();

    for (uint64_t Index = 0, Size = 0; Index < Section.getSize();
         Index += Size) {
      MCInst Inst;
      ArrayRef<uint8_t> ThisBytes = Bytes.slice(Index);
      uint64_t ThisAddr = SectionAddr + Index;
      if (!DisAsm->getInstruction(Inst, Size, ThisBytes, ThisAddr, nulls())) {
        if (Size == 0)
          Size = std::min<uint64_t>(
              ThisBytes.size(),
              DisAsm->suggestBytesToSkip(ThisBytes, ThisAddr));
        MIA->resetState();
        continue;
      }
      uint64_t Addr = Index + SectionAddr;
      uint64_t Target;
      if (MIA->isCall(Inst) &&
          MIA->evaluateBranch(Inst, SectionAddr + Index, Size, Target))
        Fn(Addr, Addr + Size, Target, Section.getIndex());
      MIA->updateState(Inst, STI.get(), Addr);
    }
  }
}

// Locate addresses of all coverage points in a file. Coverage point
// is defined as the 'address of instruction following __sanitizer_cov
// call - 1'.
static void getObjectCoveragePoints(const object::ObjectFile &O,
                                    std::set<uint64_t> *Addrs) {
  auto SanCovAddrs = findSanitizerCovFunctions(O);
  if (SanCovAddrs.empty())
    fail("__sanitizer_cov* functions not found");

  // Sanitizer coverage steps back into the call the way the sanitizer runtimes
  // do, by GetPreviousInstructionPc().
  Triple TheTriple("unknown-unknown-unknown");
  TheTriple.setArch(Triple::ArchType(O.getArch()));
  visitCallSites(
      O, [&](uint64_t, uint64_t NextAddr, uint64_t Target, uint64_t) {
        if (SanCovAddrs.count(Target))
          Addrs->insert(getPreviousInstructionPc(NextAddr, TheTriple));
      });
}

// Locate the call sites of the trace-args/trace-ret callbacks in O. A call site
// is the return address of the call minus one on every target, which is what
// the callbacks' consumers record (libFuzzer, the kernel's KCOV dataflow); it
// lies within the call, so it symbolizes to the call's location.
// The observation descriptor; see SanitizerCoverage.cpp for the format.
struct DataflowDescriptor {
  enum : uint8_t {
    F_Return = 1 << 0,
    F_Element = 1 << 1,
    F_InMemoryArg = 1 << 2,
    F_SRetObject = 1 << 3,
    F_HiddenArgs = 1 << 4,
    F_Unused = 1 << 5,
    F_Pointee = 1 << 6,
    F_Access = 1 << 7,
  };
  // The access kind of an access record.
  enum : uint8_t {
    AK_Store = 1 << 0,
    AK_Volatile = 1 << 1,
    AK_Atomic = 1 << 2,
  };
  uint8_t Version = 0;
  uint8_t Flags = 0;
  uint8_t Class = 0;
  uint8_t AccessKind = 0;
  uint16_t IRArg = 0;
  uint16_t IRArgCount = 0;
  uint16_t Element = 0;
  uint16_t AccessSize = 0;
  uint32_t Size = 0;
  uint32_t ElementOffset = 0;

  bool isAccess() const { return Flags & F_Access; }
  // The signed byte offset of an access piece from its pointer.
  int64_t accessOffset() const { return static_cast<int32_t>(ElementOffset); }
  // The llvm::AtomicOrdering of an atomic access.
  unsigned accessOrdering() const { return (AccessKind >> 4) & 7; }
};

// Version 1 describes argument and return observations; version 2, which a
// version 1 decoder skips rather than misreads, an access record.
static constexpr uint8_t DataflowDescriptorVersion = 1;
static constexpr uint8_t DataflowDescriptorAccessVersion = 2;
static constexpr size_t DataflowDescriptorSize = 20;

static bool isDataflowDescriptorVersion(uint8_t V) {
  return V == DataflowDescriptorVersion || V == DataflowDescriptorAccessVersion;
}

static StringRef getAtomicOrderingName(unsigned Ordering) {
  switch (Ordering) {
  case 1:
    return "unordered";
  case 2:
    return "monotonic";
  case 4:
    return "acquire";
  case 5:
    return "release";
  case 6:
    return "acq_rel";
  case 7:
    return "seq_cst";
  default:
    return "unknown";
  }
}

static StringRef getDataflowClassName(uint8_t Class) {
  switch (Class) {
  case 1:
    return "integer";
  case 2:
    return "pointer";
  case 3:
    return "float";
  case 4:
    return "vector";
  case 5:
    return "object";
  default:
    return "none";
  }
}

// The address of a call: in a relocatable object, where every section starts
// at address 0, the address within its section and that section's index; in
// a linked binary the address alone, with SectionedAddress::UndefSection.
struct DataflowAddr {
  uint64_t SectionIndex;
  uint64_t Addr;
  bool operator<(const DataflowAddr &Other) const {
    return std::tie(SectionIndex, Addr) <
           std::tie(Other.SectionIndex, Other.Addr);
  }
};

static uint64_t dataflowSection(const object::ObjectFile &O,
                                uint64_t SectionIndex) {
  return O.isRelocatableObject() ? SectionIndex
                                 : object::SectionedAddress::UndefSection;
}

// Read the descriptors of the __sancov_dataflow sections of O, keyed by the
// address of the call each describes. In a relocatable object the address is
// the target of the entry's relocation, in the section of its symbol;
// elsewhere the entry holds it relative to itself.
static std::map<DataflowAddr, DataflowDescriptor>
readDataflowDescriptors(const object::ObjectFile &O) {
  std::map<DataflowAddr, DataflowDescriptor> Result;
  size_t Unknown = 0;
  bool LE = O.isLittleEndian();
  auto Read = [&](ArrayRef<uint8_t> B, size_t Off, unsigned Bytes) {
    uint64_t V = 0;
    for (unsigned I = 0; I != Bytes; ++I)
      V |= uint64_t(B[Off + (LE ? I : Bytes - 1 - I)]) << (8 * I);
    return V;
  };

  // Relocation targets, per descriptor section, for relocatable objects.
  DenseMap<uint64_t, std::map<uint64_t, DataflowAddr>> RelocTargets;
  if (O.isRelocatableObject()) {
    for (object::SectionRef RelSec : O.sections()) {
      Expected<object::section_iterator> Target = RelSec.getRelocatedSection();
      if (!Target) {
        consumeError(Target.takeError());
        continue;
      }
      if (*Target == O.section_end())
        continue;
      Expected<StringRef> Name = (*Target)->getName();
      if (!Name || *Name != "__sancov_dataflow") {
        if (!Name)
          consumeError(Name.takeError());
        continue;
      }
      auto &Targets = RelocTargets[(*Target)->getIndex()];
      for (const object::RelocationRef &R : RelSec.relocations()) {
        uint64_t Addr = 0;
        uint64_t SectionIndex = object::SectionedAddress::UndefSection;
        object::symbol_iterator Sym = R.getSymbol();
        if (Sym != O.symbol_end()) {
          Expected<uint64_t> SymAddr = Sym->getAddress();
          if (!SymAddr) {
            consumeError(SymAddr.takeError());
            continue;
          }
          Addr = *SymAddr;
          Expected<object::section_iterator> SymSec = Sym->getSection();
          if (!SymSec) {
            consumeError(SymSec.takeError());
            continue;
          }
          if (*SymSec != O.section_end())
            SectionIndex = (*SymSec)->getIndex();
        }
        int64_t Addend = 0;
        if (O.isELF()) {
          if (Expected<int64_t> A = object::ELFRelocationRef(R).getAddend())
            Addend = *A;
          else
            consumeError(A.takeError());
        }
        Targets[R.getOffset()] = {SectionIndex, Addr + Addend};
      }
    }
  }

  for (object::SectionRef Section : O.sections()) {
    Expected<StringRef> Name = Section.getName();
    if (!Name) {
      consumeError(Name.takeError());
      continue;
    }
    if (*Name != "__sancov_dataflow")
      continue;
    Expected<StringRef> Contents = Section.getContents();
    failIfError(Contents);
    ArrayRef<uint8_t> Bytes = arrayRefFromStringRef(*Contents);
    // The PC entry is 32 bits, or 64 for the medium and large code models;
    // every descriptor starts with its version, which tells them apart: a
    // version is 1 to 127, where the upper half of a 64-bit PC-relative
    // offset is 0 or 0xff. Every entry has the same size whatever its version,
    // so an entry of a version this decoder does not know is skipped rather
    // than misread, and the others are still decoded.
    unsigned PCSize = 0;
    for (unsigned Candidate : {4u, 8u}) {
      size_t Stride = Candidate + DataflowDescriptorSize;
      if (Bytes.empty() || Bytes.size() % Stride)
        continue;
      bool Valid = true, Known = false;
      for (size_t Off = 0; Valid && Off < Bytes.size(); Off += Stride) {
        uint8_t Version = Bytes[Off + Candidate];
        Valid = Version >= 1 && Version <= 127;
        Known |= isDataflowDescriptorVersion(Version);
      }
      if (Valid && Known) {
        PCSize = Candidate;
        break;
      }
    }
    if (!PCSize) {
      if (!Bytes.empty())
        errs() << "WARNING: unrecognized __sancov_dataflow section in "
               << O.getFileName() << "\n";
      continue;
    }
    const auto *Targets = RelocTargets.find(Section.getIndex()) !=
                                  RelocTargets.end()
                              ? &RelocTargets[Section.getIndex()]
                              : nullptr;
    uint64_t Stride = PCSize + DataflowDescriptorSize;
    for (size_t Off = 0; Off < Bytes.size(); Off += Stride) {
      DataflowAddr PC;
      if (O.isRelocatableObject()) {
        if (!Targets || !Targets->count(Off))
          continue;
        PC = Targets->at(Off);
      } else {
        uint64_t Rel = Read(Bytes, Off, PCSize);
        if (PCSize == 4)
          Rel = static_cast<uint64_t>(static_cast<int64_t>(
              static_cast<int32_t>(static_cast<uint32_t>(Rel))));
        PC = {object::SectionedAddress::UndefSection,
              Section.getAddress() + Off + Rel};
      }
      size_t D = Off + PCSize;
      if (!isDataflowDescriptorVersion(Bytes[D])) {
        ++Unknown;
        continue;
      }
      DataflowDescriptor Desc;
      Desc.Version = Bytes[D];
      Desc.Flags = Bytes[D + 1];
      Desc.Class = Bytes[D + 2];
      Desc.AccessKind = Bytes[D + 3];
      Desc.IRArg = Read(Bytes, D + 4, 2);
      Desc.IRArgCount = Read(Bytes, D + 6, 2);
      Desc.Element = Read(Bytes, D + 8, 2);
      Desc.AccessSize = Read(Bytes, D + 10, 2);
      Desc.Size = Read(Bytes, D + 12, 4);
      Desc.ElementOffset = Read(Bytes, D + 16, 4);
      // An access record is version 2 and nothing else is; a descriptor that
      // says otherwise is not one this decoder understands.
      if (Desc.isAccess() !=
          (Desc.Version == DataflowDescriptorAccessVersion)) {
        errs() << "WARNING: malformed __sancov_dataflow descriptor in "
               << O.getFileName() << "\n";
        continue;
      }
      Result.emplace(PC, Desc);
    }
  }
  if (Unknown)
    errs() << "WARNING: skipped " << Unknown
           << " __sancov_dataflow descriptors of an unknown version in "
           << O.getFileName() << "\n";
  return Result;
}

struct DataflowSite {
  DataflowKind Kind;
  // The address of the call instruction, which its descriptor names.
  uint64_t CallAddr;
  // Its section, in a relocatable object; see DataflowAddr.
  uint64_t SectionIndex;
};

//
// A call is one when it calls a callback the binary defines, or when an
// observation descriptor names it: the descriptors also find the call sites of
// a binary whose callbacks are reached through a PLT or whose symbol table was
// stripped.
static void getObjectDataflowPoints(
    const object::ObjectFile &O, std::map<DataflowAddr, DataflowSite> *Points,
    const std::map<DataflowAddr, DataflowDescriptor> &Descs) {
  auto ArgsAddrs = findCallbackAddrs(O, isDataflowArgsSymbol);
  auto RetAddrs = findCallbackAddrs(O, isDataflowRetSymbol);
  if (ArgsAddrs.empty() && RetAddrs.empty() && Descs.empty())
    fail("__sanitizer_cov_trace_args and __sanitizer_cov_trace_ret functions "
         "not found");

  visitCallSites(O, [&](uint64_t Addr, uint64_t NextAddr, uint64_t Target,
                        uint64_t SectionIndex) {
    uint64_t Sec = dataflowSection(O, SectionIndex);
    DataflowAddr Point{Sec, NextAddr - 1};
    // The descriptor says what the call observes even where identical code
    // folding merged the two callbacks into one.
    if (auto It = Descs.find({Sec, Addr}); It != Descs.end())
      Points->emplace(
          Point, DataflowSite{It->second.Flags & DataflowDescriptor::F_Return
                                  ? DataflowKind::Ret
                              : It->second.isAccess() ? DataflowKind::Access
                                                      : DataflowKind::Args,
                              Addr, Sec});
    else if (ArgsAddrs.count(Target))
      Points->emplace(Point, DataflowSite{DataflowKind::Args, Addr, Sec});
    else if (RetAddrs.count(Target))
      Points->emplace(Point, DataflowSite{DataflowKind::Ret, Addr, Sec});
  });
}

static void
visitObjectFiles(const object::Archive &A,
                 function_ref<void(const object::ObjectFile &)> Fn) {
  Error Err = Error::success();
  for (auto &C : A.children(Err)) {
    Expected<std::unique_ptr<object::Binary>> ChildOrErr = C.getAsBinary();
    failIfError(ChildOrErr);
    if (auto *O = dyn_cast<object::ObjectFile>(&*ChildOrErr.get()))
      Fn(*O);
    else
      failIfError(object::object_error::invalid_file_type);
  }
  failIfError(std::move(Err));
}

static void
visitObjectFiles(const std::string &FileName,
                 function_ref<void(const object::ObjectFile &)> Fn) {
  Expected<object::OwningBinary<object::Binary>> BinaryOrErr =
      object::createBinary(FileName);
  if (!BinaryOrErr)
    failIfError(BinaryOrErr);

  object::Binary &Binary = *BinaryOrErr.get().getBinary();
  if (object::Archive *A = dyn_cast<object::Archive>(&Binary))
    visitObjectFiles(*A, Fn);
  else if (object::ObjectFile *O = dyn_cast<object::ObjectFile>(&Binary))
    Fn(*O);
  else
    failIfError(object::object_error::invalid_file_type);
}

static std::set<uint64_t>
findSanitizerCovFunctions(const std::string &FileName) {
  std::set<uint64_t> Result;
  visitObjectFiles(FileName, [&](const object::ObjectFile &O) {
    auto Addrs = findSanitizerCovFunctions(O);
    Result.insert(Addrs.begin(), Addrs.end());
  });
  return Result;
}

// Locate addresses of all coverage points in a file. Coverage point
// is defined as the 'address of instruction following __sanitizer_cov
// call - 1'.
static std::set<uint64_t> findCoveragePointAddrs(const std::string &FileName) {
  std::set<uint64_t> Result;
  visitObjectFiles(FileName, [&](const object::ObjectFile &O) {
    getObjectCoveragePoints(O, &Result);
  });
  return Result;
}

static void printCovPoints(const std::string &ObjFile, raw_ostream &OS) {
  for (uint64_t Addr : findCoveragePointAddrs(ObjFile)) {
    OS << "0x";
    OS.write_hex(Addr);
    OS << "\n";
  }
}

// Locate the call sites of the trace-args/trace-ret callbacks in a file.
static std::map<DataflowAddr, DataflowSite>
findDataflowPointAddrs(const std::string &FileName) {
  std::map<DataflowAddr, DataflowSite> Result;
  visitObjectFiles(FileName, [&](const object::ObjectFile &O) {
    getObjectDataflowPoints(O, &Result, readDataflowDescriptors(O));
  });
  return Result;
}

// Print the trace-args/trace-ret call sites of a file, one per line:
// <address> args|ret.
static void printDataflowPoints(const std::string &ObjFile, raw_ostream &OS) {
  for (auto [Addr, Site] : findDataflowPointAddrs(ObjFile)) {
    OS << "0x";
    OS.write_hex(Addr.Addr);
    OS << " " << getDataflowKindName(Site.Kind) << "\n";
  }
}

// ---------- trace-args/trace-ret observations ----------
//
// What sancov can say about an observation, and how sure it is:
//
// - From the call site alone, the observation exactly: every observation has
//   a call of its own. Its function, file and line come from the symbol table
//   and the line table.
// - From the observation descriptor the compiler emits for every trace call
//   into __sancov_dataflow, with or without debug information: the IR
//   argument, the element of a first-class aggregate, the value class and
//   size, whether it is an object in memory, and whether a pointer came with
//   the bytes it points to - how many, the IR alone decided.
// - From the debug-only source map (DW_TAG_LLVM_sancov_observation), exactly:
//   which source parameter, and which bits of it, an argument observation
//   holds. From the subprogram's type, the type of a return.
// - From DWARF types, the members of what was observed, and of what a pointer
//   points to: which of them the bytes read behind it hold, wholly or in part,
//   which is how a raw pointee snapshot is cut into members.
// - Without the source map, at most a positional guess, labelled as one, and
//   only where no split aggregate or hidden argument makes it ambiguous.
// - For an access record (-sanitizer-coverage-trace-pointee-access), the
//   pointer argument it went through, resolved as that argument's
//   observation would be, and the members of the pointee its bytes overlap.
//   It is the value of one load or store, never a snapshot of the pointee.
//
// Nothing here disassembles the code around a call or reimplements an ABI.

// ---------- DWARF ----------

static DWARFDie getReferencedType(const DWARFDie &D) {
  if (auto Ref = D.findRecursively(dwarf::DW_AT_type))
    return D.getAttributeValueAsReferencedDie(*Ref);
  return {};
}

// Strip typedefs and qualifiers.
static DWARFDie stripTypedefs(DWARFDie T) {
  for (unsigned I = 0; T && I < 32; ++I) {
    switch (T.getTag()) {
    case dwarf::DW_TAG_typedef:
    case dwarf::DW_TAG_const_type:
    case dwarf::DW_TAG_volatile_type:
    case dwarf::DW_TAG_restrict_type:
    case dwarf::DW_TAG_atomic_type:
    case dwarf::DW_TAG_LLVM_ptrauth_type:
      T = getReferencedType(T);
      continue;
    default:
      return T;
    }
  }
  return T;
}

static bool isPointerLike(const DWARFDie &T) {
  return T && (T.getTag() == dwarf::DW_TAG_pointer_type ||
               T.getTag() == dwarf::DW_TAG_reference_type ||
               T.getTag() == dwarf::DW_TAG_rvalue_reference_type);
}

static bool isAggregate(const DWARFDie &T) {
  return T && (T.getTag() == dwarf::DW_TAG_structure_type ||
               T.getTag() == dwarf::DW_TAG_class_type ||
               T.getTag() == dwarf::DW_TAG_union_type);
}

static std::string getTypeName(const DWARFDie &T) {
  if (!T)
    return "void";
  std::string Name;
  raw_string_ostream OS(Name);
  dumpTypeQualifiedName(T, OS);
  return Name;
}

static std::optional<uint64_t> getTypeByteSize(DWARFDie T) {
  T = stripTypedefs(T);
  if (!T)
    return std::nullopt;
  if (auto Size = dwarf::toUnsigned(T.find(dwarf::DW_AT_byte_size)))
    return Size;
  if (isPointerLike(T))
    return T.getDwarfUnit()->getAddressByteSize();
  if (T.getTag() == dwarf::DW_TAG_array_type) {
    std::optional<uint64_t> Elem = getTypeByteSize(getReferencedType(T));
    uint64_t Count = 1;
    for (const DWARFDie &Sub : T.children()) {
      if (Sub.getTag() != dwarf::DW_TAG_subrange_type)
        continue;
      if (auto C = dwarf::toUnsigned(Sub.find(dwarf::DW_AT_count)))
        Count *= *C;
      else if (auto U = dwarf::toUnsigned(Sub.find(dwarf::DW_AT_upper_bound)))
        Count *= *U + 1;
      else
        return std::nullopt;
    }
    if (Elem)
      return *Elem * Count;
  }
  return std::nullopt;
}

// A leaf member of an aggregate, flattened through nested aggregates.
struct DataflowField {
  std::string Name;
  std::string Type;
  uint64_t BitOffset; // In the outermost object.
  uint64_t BitSize;
};

static void collectFields(DWARFDie T, uint64_t BaseBit, const std::string &Prefix,
                          std::vector<DataflowField> &Fields,
                          unsigned Depth = 0) {
  T = stripTypedefs(T);
  if (!isAggregate(T) || Depth > 8)
    return;
  for (const DWARFDie &M : T.children()) {
    if (M.getTag() != dwarf::DW_TAG_member &&
        M.getTag() != dwarf::DW_TAG_inheritance)
      continue;
    // A static member has no storage in the object.
    if (M.find(dwarf::DW_AT_external) || M.find(dwarf::DW_AT_declaration))
      continue;
    DWARFDie MT = getReferencedType(M);
    uint64_t Bit = BaseBit;
    if (auto DBO = dwarf::toUnsigned(M.find(dwarf::DW_AT_data_bit_offset)))
      Bit += *DBO;
    else if (auto DML =
                 dwarf::toUnsigned(M.find(dwarf::DW_AT_data_member_location)))
      Bit += 8 * *DML;
    const char *MName = M.getShortName();
    std::string Name =
        Prefix + (MName ? MName : (M.getTag() == dwarf::DW_TAG_inheritance
                                       ? getTypeName(MT)
                                       : std::string("<anonymous>")));
    uint64_t Bits;
    if (auto BS = dwarf::toUnsigned(M.find(dwarf::DW_AT_bit_size)))
      Bits = *BS;
    else if (auto Bytes = getTypeByteSize(MT))
      Bits = 8 * *Bytes;
    else
      continue;
    // A member of no size, such as a Rust PhantomData, has no bits to hold.
    if (!Bits)
      continue;
    if (isAggregate(stripTypedefs(MT))) {
      size_t Before = Fields.size();
      collectFields(MT, Bit, Name + ".", Fields, Depth + 1);
      if (Fields.size() != Before)
        continue;
    }
    Fields.push_back({Name, getTypeName(MT), Bit, Bits});
  }
}

// The fields of an object of type T, or T itself as one field if it is no
// aggregate.
static std::vector<DataflowField> getFields(const DWARFDie &T,
                                            StringRef Whole) {
  std::vector<DataflowField> Fields;
  collectFields(T, 0, "", Fields);
  // An aggregate DWARF gives no members for - Swift describes its types'
  // layout in runtime metadata, not in DWARF - is one opaque field.
  if (Fields.empty() && T)
    if (auto Bytes = getTypeByteSize(T))
      Fields.push_back({Whole.str(), getTypeName(T), 0, 8 * *Bytes});
  return Fields;
}

// One DW_TAG_LLVM_sancov_observation: bits [ValueBit, ValueBit + Bits) of the
// observed value are bits [VarBit, VarBit + Bits) of Var, or, if Indirect, the
// value is Var's address.
struct DataflowMapPiece {
  DWARFDie Var;
  uint64_t SourceArg = 0;
  bool Indirect = false;
  uint64_t ValueBit = 0;
  uint64_t VarBit = 0;
  uint64_t Bits = 0;
};

static std::vector<DataflowMapPiece>
findMapPieces(const DWARFDie &Subprogram, uint64_t IRArg, uint64_t Element) {
  std::vector<DataflowMapPiece> Pieces;
  for (const DWARFDie &C : Subprogram.children()) {
    if (C.getTag() != dwarf::DW_TAG_LLVM_sancov_observation)
      continue;
    if (dwarf::toUnsigned(C.find(dwarf::DW_AT_LLVM_sancov_ir_arg)) != IRArg ||
        dwarf::toUnsigned(C.find(dwarf::DW_AT_LLVM_sancov_element), 0) !=
            Element)
      continue;
    DataflowMapPiece P;
    P.Var = C.getAttributeValueAsReferencedDie(dwarf::DW_AT_LLVM_sancov_variable);
    if (!P.Var)
      continue;
    P.SourceArg =
        dwarf::toUnsigned(C.find(dwarf::DW_AT_LLVM_sancov_source_arg), 0);
    P.Indirect = C.find(dwarf::DW_AT_LLVM_sancov_indirect).has_value();
    P.ValueBit = dwarf::toUnsigned(
        C.find(dwarf::DW_AT_LLVM_sancov_value_bit_offset), 0);
    P.VarBit = dwarf::toUnsigned(C.find(dwarf::DW_AT_data_bit_offset), 0);
    P.Bits = dwarf::toUnsigned(C.find(dwarf::DW_AT_bit_size), 0);
    Pieces.push_back(P);
  }
  return Pieces;
}

static std::vector<DWARFDie> getFormalParameters(const DWARFDie &Subprogram) {
  std::vector<DWARFDie> Params;
  for (const DWARFDie &C : Subprogram.children())
    if (C.getTag() == dwarf::DW_TAG_formal_parameter)
      Params.push_back(C);
  // A concrete out-of-line instance may describe its parameters only through
  // its abstract origin.
  if (Params.empty())
    if (DWARFDie Origin = Subprogram.getAttributeValueAsReferencedDie(
            dwarf::DW_AT_abstract_origin))
      for (const DWARFDie &C : Origin.children())
        if (C.getTag() == dwarf::DW_TAG_formal_parameter)
          Params.push_back(C);
  return Params;
}

// The source interpretation of one observation.
struct DataflowSource {
  enum Provenance { Exact, Heuristic, Unresolved };
  Provenance Prov = Unresolved;
  std::string Method; // How it was resolved, or why it was not.
  std::string Summary;
  // The source parameter of an argument observation.
  std::string ParamName;
  uint64_t ParamNumber = 0;
  bool Artificial = false; // A hidden argument's artificial variable.
  // The type of the parameter, or of the return value. The DWARF context is
  // gone by the time a report is written, so only names are kept.
  std::string TypeName;
  bool Indirect = false;
  std::vector<DataflowMapPiece> Pieces;
  // The members of what was observed, with where their bits are in the
  // observed value (Direct) or in the object it addresses (Indirect, Object).
  struct Field {
    DataflowField F;
    std::optional<uint64_t> ValueBit; // In `val`, for a value observation.
    bool Complete = true;             // Wholly within the observation.
    bool Observed = true;             // Any of it within the observation.
  };
  std::vector<Field> Fields;
  std::string FieldsProvenance;
  // For a pointer or reference value: what it points to, and how many bytes
  // of that the runtime read behind it, which the IR alone bounds: 0 for a
  // pointer it had no dereferenceable attribute for.
  std::optional<std::string> PointeeType;
  std::vector<Field> PointeeFields;
  uint64_t PointeeBytesRead = 0;
  // For an access record: the members of the object the pointer points to -
  // or of the parameter itself, if the pointer is its address - that the
  // accessed bytes overlap. An access is not the object's state: it is the
  // value of one load or store, and says nothing of the bytes around it.
  struct AccessMember {
    std::string Name;       // Member path within the object; "" for all of it.
    std::string Expression; // The source expression, e.g. "o->in.x".
    std::string Type;
    uint64_t BitOffset; // Of the member, in the object.
    uint64_t BitSize;
    uint64_t ValueBit;  // Where the overlap starts in the value.
    uint64_t MemberBit; // Where it starts in the member.
    uint64_t Bits;      // How many bits overlap.
    bool Complete;      // The access holds all of the member.
  };
  struct AccessInfo {
    std::string ObjectType;
    std::vector<AccessMember> Members;
    // The bytes lie before the object (container_of), or some of them past
    // it without an element of an array of such objects to put them in.
    bool Outside = false;
    // The bytes are in element Index of an array of such objects (p[Index]).
    std::optional<uint64_t> Index;
  };
  std::optional<AccessInfo> Access;
  // The DWARF type of the parameter, while the DWARF context is alive.
  DWARFDie ParamTypeDie;
};

static StringRef getProvenanceName(DataflowSource::Provenance P) {
  switch (P) {
  case DataflowSource::Exact:
    return "exact";
  case DataflowSource::Heuristic:
    return "heuristic";
  case DataflowSource::Unresolved:
    return "unresolved";
  }
  llvm_unreachable("bad provenance");
}

// The pointer-typed member of aggregate T whose bits start at Bit, through
// nested aggregates: what a pointer observation holds when it is one piece of
// a parameter, such as the vtable of a Rust trait object.
static DWARFDie findPointerMember(DWARFDie T, uint64_t Bit,
                                  unsigned Depth = 0) {
  T = stripTypedefs(T);
  if (!isAggregate(T) || Depth > 8)
    return {};
  for (const DWARFDie &M : T.children()) {
    if (M.getTag() != dwarf::DW_TAG_member &&
        M.getTag() != dwarf::DW_TAG_inheritance)
      continue;
    if (M.find(dwarf::DW_AT_external) || M.find(dwarf::DW_AT_declaration) ||
        M.find(dwarf::DW_AT_bit_size))
      continue;
    std::optional<uint64_t> DML =
        dwarf::toUnsigned(M.find(dwarf::DW_AT_data_member_location));
    if (!DML)
      continue;
    uint64_t MBit = 8 * *DML;
    DWARFDie MT = stripTypedefs(getReferencedType(M));
    std::optional<uint64_t> Bytes = getTypeByteSize(MT);
    if (!Bytes || Bit < MBit || Bit >= MBit + 8 * *Bytes)
      continue;
    if (MBit == Bit && isPointerLike(MT))
      return MT;
    return findPointerMember(MT, Bit - MBit, Depth + 1);
  }
  return {};
}

// Fill in the type-derived parts of Src for a value or object of type T.
static void describeType(DataflowSource &Src, const DataflowDescriptor &Desc,
                         DWARFDie T, StringRef Whole) {
  Src.TypeName = getTypeName(T);
  DWARFDie Stripped = stripTypedefs(T);
  bool IsObject = Desc.Class == 5;
  bool Pointee = Desc.Flags & DataflowDescriptor::F_Pointee;
  // Which bits behind `val` the runtime read: all of an object, the first
  // `size` bytes behind a pointer it was told is dereferenceable that far, and
  // none behind any other pointer.
  uint64_t ReadBits = IsObject  ? UINT64_MAX
                      : Pointee ? 8 * uint64_t(Desc.Size)
                                : 0;
  auto InMemory = [&](const DataflowField &F) {
    DataflowSource::Field Out{F, std::nullopt, true, true};
    if (F.BitOffset >= ReadBits)
      Out.Complete = Out.Observed = false;
    else if (F.BitOffset + F.BitSize > ReadBits)
      Out.Complete = false;
    return Out;
  };
  if (Src.Indirect || IsObject) {
    // `val` is the address of an object of type T.
    for (DataflowField &F : getFields(T, Whole))
      Src.Fields.push_back(InMemory(F));
    return;
  }
  // `val` is a pointer: the parameter, or the one piece of it the value holds.
  DWARFDie PointerType;
  if (isPointerLike(Stripped))
    PointerType = Stripped;
  else if (Pointee && Src.Pieces.size() == 1 && Src.Pieces[0].ValueBit == 0)
    PointerType = findPointerMember(T, Src.Pieces[0].VarBit);
  if (PointerType) {
    DWARFDie PT = getReferencedType(PointerType);
    Src.PointeeType = getTypeName(PT);
    Src.PointeeBytesRead = Pointee ? Desc.Size : 0;
    for (DataflowField &F : getFields(PT, "*"))
      Src.PointeeFields.push_back(InMemory(F));
  }
  // Which bits of `val` hold which members: from the map's pieces if there
  // are any, or the whole value if it is the whole parameter.
  std::vector<DataflowMapPiece> Pieces = Src.Pieces;
  if (Pieces.empty())
    return;
  for (DataflowField &F : getFields(T, Whole)) {
    for (const DataflowMapPiece &P : Pieces) {
      uint64_t Lo = std::max(F.BitOffset, P.VarBit);
      uint64_t Hi = std::min(F.BitOffset + F.BitSize, P.VarBit + P.Bits);
      if (Lo >= Hi)
        continue;
      bool Complete = Lo == F.BitOffset && Hi == F.BitOffset + F.BitSize;
      Src.Fields.push_back({F, P.ValueBit + (Lo - P.VarBit), Complete});
    }
  }
}

static std::string describeObservation(DataflowKind Kind,
                                       const DataflowDescriptor &Desc) {
  std::string S;
  if (Kind == DataflowKind::Args)
    S = "IR argument " + std::to_string(Desc.IRArg);
  else
    S = "return value";
  if (Desc.Flags & DataflowDescriptor::F_Element)
    S += " element " + std::to_string(Desc.Element);
  return S;
}

// The inlined subroutines of Scope whose code holds Addr, outermost first.
static void getInlinedScopes(DWARFDie Scope, uint64_t Addr,
                             SmallVectorImpl<DWARFDie> &Chain) {
  for (DWARFDie Child : Scope.children()) {
    dwarf::Tag Tag = Child.getTag();
    if (Tag != dwarf::DW_TAG_inlined_subroutine &&
        Tag != dwarf::DW_TAG_lexical_block)
      continue;
    Expected<bool> Holds = Child.addressRangeContainsAddress(Addr);
    if (!Holds) {
      consumeError(Holds.takeError());
      continue;
    }
    if (!*Holds)
      continue;
    if (Tag == dwarf::DW_TAG_inlined_subroutine)
      Chain.push_back(Child);
    getInlinedScopes(Child, Addr, Chain);
    return;
  }
}

// The innermost inlined subroutine of Function holding Addr, or Function.
static DWARFDie getInnermostFrame(DWARFDie Function, uint64_t Addr) {
  SmallVector<DWARFDie, 4> Chain;
  getInlinedScopes(Function, Addr, Chain);
  return Chain.empty() ? Function : Chain.back();
}

// The subprogram whose code holds Addr in its section. In a relocatable object
// every section starts at address 0 - a module's .text and .init.text, say -
// so the address alone, which is all DWARFContext::getDIEsForAddress() takes,
// can name a function in another section.
static DWARFDie findSubprogram(DWARFDie Scope, object::SectionedAddress Addr) {
  for (DWARFDie Child : Scope.children()) {
    dwarf::Tag Tag = Child.getTag();
    if (Tag == dwarf::DW_TAG_subprogram) {
      Expected<DWARFAddressRangesVector> Ranges = Child.getAddressRanges();
      if (!Ranges) {
        consumeError(Ranges.takeError());
        continue;
      }
      for (const DWARFAddressRange &R : *Ranges)
        if (R.SectionIndex == Addr.SectionIndex && R.LowPC <= Addr.Address &&
            Addr.Address < R.HighPC)
          return Child;
    } else if (Tag == dwarf::DW_TAG_namespace ||
               Tag == dwarf::DW_TAG_structure_type ||
               Tag == dwarf::DW_TAG_class_type || Tag == dwarf::DW_TAG_module) {
      if (DWARFDie Found = findSubprogram(Child, Addr))
        return Found;
    }
  }
  return {};
}

static DataflowSource resolveDataflowSource(DWARFContext *DICtx,
                                            object::SectionedAddress Call,
                                            DataflowKind Kind,
                                            const DataflowDescriptor *Desc,
                                            bool OutermostFrame = false) {
  uint64_t CallAddr = Call.Address;
  DataflowSource Src;
  auto Unresolved = [&](StringRef Why) {
    Src.Prov = DataflowSource::Unresolved;
    Src.Method = Why.str();
    Src.Summary =
        (Desc ? describeObservation(Kind, *Desc)
              : std::string(Kind == DataflowKind::Args ? "argument"
                                                       : "return value")) +
        (Kind == DataflowKind::Args ? " -> source parameter unresolved"
                                    : " -> source type unresolved") +
        " (" + Why.str() + ")";
    return Src;
  };
  if (!Desc)
    return Unresolved("no observation descriptor");
  if (!DICtx || !DICtx->getNumCompileUnits())
    return Unresolved("no debug information");

  DWARFDie Function;
  if (Call.SectionIndex == object::SectionedAddress::UndefSection) {
    DWARFContext::DIEsForAddress DIEs =
        DICtx->getDIEsForAddress(CallAddr, /*CheckDWO=*/true);
    if (DIEs)
      Function = DIEs.FunctionDIE;
  } else {
    for (const auto &CU : DICtx->compile_units())
      if ((Function = findSubprogram(
               CU->getUnitDIE(/*ExtractUnitDIEOnly=*/false), Call)))
        break;
  }
  if (!Function)
    return Unresolved("no subprogram for the call site");
  // A trace call inlined after instrumentation reports for the function it was
  // instrumented in, not for the one it is in now. An access record has the
  // location of its access, which may be in a callee inlined before
  // instrumentation; it reports for the function that holds the call.
  DWARFDie Subprogram =
      OutermostFrame ? Function : getInnermostFrame(Function, CallAddr);
  bool Inlined = Subprogram != Function;

  std::string Obs = describeObservation(Kind, *Desc);
  if (Kind == DataflowKind::Ret) {
    // The declared return type is exact; which bytes of it an element of a
    // first-class aggregate return holds follows the IR layout of the value
    // the front end coerced the return into.
    Src.Prov = DataflowSource::Exact;
    Src.Method = "subprogram return type";
    DWARFDie T = getReferencedType(Subprogram);
    Src.TypeName = getTypeName(T);
    Src.Summary = Obs + " -> type \"" + Src.TypeName + "\" [exact: " +
                  Src.Method + "]";
    if (!T)
      return Src;
    if (Desc->Class == 5) {
      describeType(Src, *Desc, T, "return");
      return Src;
    }
    DataflowMapPiece Whole;
    Whole.ValueBit = 0;
    Whole.VarBit = 8 * uint64_t(Desc->ElementOffset);
    // `size` of a pointer reported with its pointee is the bytes read behind
    // it; the value itself is the pointer.
    Whole.Bits = Desc->Flags & DataflowDescriptor::F_Pointee
                     ? 8 * uint64_t(T.getDwarfUnit()->getAddressByteSize())
                     : 8 * uint64_t(Desc->Size);
    if (Desc->Size)
      Src.Pieces.push_back(Whole);
    describeType(Src, *Desc, T, "return");
    if (Desc->Flags & DataflowDescriptor::F_Element)
      Src.FieldsProvenance = "heuristic: IR element offset";
    return Src;
  }

  // An argument: the compiler's source map first.
  if (!Inlined) {
    std::vector<DataflowMapPiece> Pieces =
        findMapPieces(Subprogram, Desc->IRArg, Desc->Element);
    if (!Pieces.empty()) {
      Src.Prov = DataflowSource::Exact;
      Src.Method = "compiler source map";
      Src.Pieces = Pieces;
      const DataflowMapPiece &P = Pieces.front();
      Src.Indirect = P.Indirect;
      const char *Name = P.Var.getName(DINameKind::ShortName);
      Src.ParamName = Name ? Name : "";
      Src.ParamNumber = P.SourceArg;
      DWARFDie T = getReferencedType(P.Var);
      // A variable rather than a parameter: an artificial one the front end
      // describes a hidden argument with.
      Src.Artificial = P.Var.getTag() != dwarf::DW_TAG_formal_parameter;
      std::string Entity =
          Src.Artificial ? "artificial variable" : "source parameter";
      std::string What = (Src.Indirect ? "address of " : "") + Entity + " \"";
      std::string Bits;
      if (!Src.Indirect) {
        std::optional<uint64_t> VarBytes = getTypeByteSize(T);
        bool Whole = Pieces.size() == 1 && P.VarBit == 0 && P.ValueBit == 0 &&
                     VarBytes && P.Bits >= 8 * *VarBytes;
        if (!Whole)
          for (const DataflowMapPiece &Q : Pieces)
            Bits += " bits [" + std::to_string(Q.VarBit) + ", " +
                    std::to_string(Q.VarBit + Q.Bits) + ")";
      }
      Src.ParamTypeDie = T;
      Src.Summary = Obs + " -> " + What + Src.ParamName + "\"" + Bits +
                    " [exact: compiler source map]";
      if (Src.ParamName.empty())
        Src.Summary = Obs + " -> " + (Src.Indirect ? "address of " : "") +
                      Entity + " #" + std::to_string(Src.ParamNumber) + Bits +
                      " [exact: compiler source map]";
      describeType(Src, *Desc, T, Src.ParamName);
      return Src;
    }
  }

  // Without it, a positional guess, where the IR signature can still match
  // the source one: no hidden IR argument, as many IR arguments as source
  // parameters. A split aggregate breaks the second.
  std::vector<DWARFDie> Params = getFormalParameters(Subprogram);
  if (Params.empty())
    return Unresolved("no source parameters in the debug information");
  if (Desc->Flags & DataflowDescriptor::F_HiddenArgs)
    return Unresolved("no source map, and a hidden IR argument makes "
                      "positional mapping ambiguous");
  if (Desc->IRArgCount != Params.size())
    return Unresolved("no source map, and " + std::to_string(Desc->IRArgCount) +
                      " IR arguments for " + std::to_string(Params.size()) +
                      " source parameters make positional mapping ambiguous");
  if (Desc->IRArg >= Params.size())
    return Unresolved("IR argument beyond the source parameters");
  const DWARFDie &Param = Params[Desc->IRArg];
  Src.Prov = DataflowSource::Heuristic;
  Src.Method = "positional";
  const char *Name = Param.getName(DINameKind::ShortName);
  Src.ParamName = Name ? Name : "";
  Src.ParamNumber = Desc->IRArg + 1;
  Src.Summary = Obs + " -> source parameter " +
                (Src.ParamName.empty() ? "#" + std::to_string(Src.ParamNumber)
                                       : "\"" + Src.ParamName + "\"") +
                " [heuristic: positional]";
  // Which bits of the parameter the value holds is unknown, and so is whether
  // it is the parameter or its address: only the type is given - and, for a
  // pointer whose pointee the runtime read, what that pointee is.
  Src.TypeName = getTypeName(getReferencedType(Param));
  Src.ParamTypeDie = getReferencedType(Param);
  if (Desc->Flags & DataflowDescriptor::F_Pointee)
    if (DWARFDie T = getReferencedType(Param); isPointerLike(stripTypedefs(T)))
      describeType(Src, *Desc, T, Src.ParamName);
  return Src;
}

// ---------- Access records ----------
//
// An access record is the value of one load or store the function made
// through a pointer argument: piece `element` of it, `size` bytes at signed
// byte offset `element offset` from the pointer. The pointer's parameter is
// found as an argument observation's would be; the DWARF type of what it
// points to says which members those bytes are, wholly or in part. The bytes
// around them were not observed, and nothing says what they held.

static std::string describeAccess(const DataflowDescriptor &Desc) {
  std::string S = "IR argument " + std::to_string(Desc.IRArg) + " ";
  if (Desc.AccessKind & DataflowDescriptor::AK_Volatile)
    S += "volatile ";
  if (Desc.AccessKind & DataflowDescriptor::AK_Atomic)
    S += std::string("atomic ") +
         getAtomicOrderingName(Desc.accessOrdering()).str() + " ";
  S += Desc.AccessKind & DataflowDescriptor::AK_Store ? "store" : "load";
  S += " of " + std::to_string(Desc.Size) +
       (Desc.Size == 1 ? " byte" : " bytes") + " at offset " +
       std::to_string(Desc.accessOffset());
  if (Desc.Flags & DataflowDescriptor::F_Element)
    S += " (piece " + std::to_string(Desc.Element) + " of a " +
         std::to_string(Desc.AccessSize) + "-byte access)";
  return S;
}

// The number of elements of array type T, if it has one dimension of known
// count; 0 if its count is unknown, as a flexible array member's is.
static std::optional<uint64_t> getArrayCount(DWARFDie T) {
  std::optional<uint64_t> Count;
  for (const DWARFDie &Sub : T.children()) {
    if (Sub.getTag() != dwarf::DW_TAG_subrange_type)
      continue;
    if (Count)
      return std::nullopt; // More than one dimension.
    if (auto C = dwarf::toUnsigned(Sub.find(dwarf::DW_AT_count)))
      Count = *C;
    else if (auto U = dwarf::toUnsigned(Sub.find(dwarf::DW_AT_upper_bound)))
      Count = *U + 1;
    else
      Count = 0;
  }
  return Count;
}

namespace {
// Collects the members of an object that bits [Lo, Hi) of it overlap.
struct AccessMemberCollector {
  int64_t Lo, Hi;
  std::vector<DataflowSource::AccessMember> &Out;

  void emit(const std::string &Name, DWARFDie T, int64_t Bit, uint64_t Bits) {
    int64_t OLo = std::max(Bit, Lo);
    int64_t OHi = std::min(Bit + int64_t(Bits), Hi);
    if (OLo >= OHi)
      return;
    Out.push_back({Name, "", getTypeName(T), uint64_t(Bit), Bits,
                   uint64_t(OLo - Lo), uint64_t(OLo - Bit), uint64_t(OHi - OLo),
                   OLo == Bit && OHi == Bit + int64_t(Bits)});
  }

  // An object of type T at bit Bit, Bits wide if known, named Name.
  void visit(DWARFDie T, int64_t Bit, std::optional<uint64_t> Bits,
             const std::string &Name, unsigned Depth) {
    DWARFDie S = stripTypedefs(T);
    if (Bits && (Bit >= Hi || Bit + int64_t(*Bits) <= Lo))
      return;
    if (Depth > 8 || !S) {
      if (Bits)
        emit(Name, T, Bit, *Bits);
      return;
    }
    if (isAggregate(S)) {
      size_t Before = Out.size();
      std::string Prefix = Name.empty() ? "" : Name + ".";
      for (const DWARFDie &M : S.children()) {
        if (M.getTag() != dwarf::DW_TAG_member &&
            M.getTag() != dwarf::DW_TAG_inheritance)
          continue;
        if (M.find(dwarf::DW_AT_external) || M.find(dwarf::DW_AT_declaration))
          continue;
        DWARFDie MT = getReferencedType(M);
        int64_t MBit = Bit;
        if (auto DBO = dwarf::toUnsigned(M.find(dwarf::DW_AT_data_bit_offset)))
          MBit += *DBO;
        else if (auto DML = dwarf::toUnsigned(
                     M.find(dwarf::DW_AT_data_member_location)))
          MBit += 8 * *DML;
        const char *MName = M.getShortName();
        std::string MemberName =
            Prefix + (MName ? MName
                            : (M.getTag() == dwarf::DW_TAG_inheritance
                                   ? getTypeName(MT)
                                   : std::string("<anonymous>")));
        std::optional<uint64_t> MBits;
        if (auto BS = dwarf::toUnsigned(M.find(dwarf::DW_AT_bit_size)))
          MBits = *BS;
        else if (auto Bytes = getTypeByteSize(MT))
          MBits = 8 * *Bytes;
        else if (stripTypedefs(MT).getTag() != dwarf::DW_TAG_array_type)
          continue;
        if (MBits && !*MBits)
          continue;
        visit(MT, MBit, MBits, MemberName, Depth + 1);
      }
      if (Out.size() == Before && Bits)
        emit(Name, T, Bit, *Bits);
      return;
    }
    if (S.getTag() == dwarf::DW_TAG_array_type) {
      DWARFDie ET = getReferencedType(S);
      std::optional<uint64_t> EBytes = getTypeByteSize(ET);
      std::optional<uint64_t> Count = getArrayCount(S);
      if (!EBytes || !*EBytes || !Count) {
        if (Bits)
          emit(Name, T, Bit, *Bits);
        return;
      }
      int64_t EBits = 8 * *EBytes;
      int64_t First = std::max<int64_t>(0, (Lo - Bit) / EBits);
      int64_t Last = (Hi - 1 - Bit) / EBits;
      if (*Count)
        Last = std::min<int64_t>(Last, *Count - 1);
      for (int64_t I = First; I <= Last && I - First < 64; ++I)
        visit(ET, Bit + I * EBits, uint64_t(EBits),
              Name + "[" + std::to_string(I) + "]", Depth + 1);
      return;
    }
    if (Bits)
      emit(Name, T, Bit, *Bits);
  }
};
} // namespace

// The source expression of member Name of what parameter Param points to, or,
// if Indirect, of the parameter itself, in array element Index of it if any.
static std::string getAccessExpression(StringRef Param, bool Indirect,
                                       std::optional<uint64_t> Index,
                                       StringRef Name) {
  std::string Base = Param.str();
  if (Index)
    Base += "[" + std::to_string(*Index) + "]";
  else if (!Indirect && (Name.empty() || Name.starts_with("[")))
    Base = Name.empty() ? "*" + Base : "(*" + Base + ")";
  if (Name.empty())
    return Base;
  if (Name.starts_with("["))
    return Base + Name.str();
  return Base + (Indirect || Index ? "." : "->") + Name.str();
}

static DataflowSource resolveAccessSource(DWARFContext *DICtx,
                                          object::SectionedAddress Call,
                                          const DataflowDescriptor &Desc,
                                          bool LittleEndian) {
  // The pointer, as an argument observation of it would be resolved.
  DataflowDescriptor ArgDesc;
  ArgDesc.Version = DataflowDescriptorVersion;
  ArgDesc.Flags = Desc.Flags & DataflowDescriptor::F_HiddenArgs;
  ArgDesc.Class = 2;
  ArgDesc.IRArg = Desc.IRArg;
  ArgDesc.IRArgCount = Desc.IRArgCount;
  DataflowSource Src = resolveDataflowSource(DICtx, Call, DataflowKind::Args,
                                             &ArgDesc, /*OutermostFrame=*/true);
  DWARFDie T = Src.ParamTypeDie;
  Src.ParamTypeDie = {};
  std::string What = describeAccess(Desc);
  if (Src.Prov == DataflowSource::Unresolved) {
    Src.Summary = What + " -> source parameter unresolved (" + Src.Method + ")";
    return Src;
  }
  // What was read behind the pointer at the call is not this record's.
  Src.Fields.clear();
  Src.FieldsProvenance.clear();
  Src.PointeeType.reset();
  Src.PointeeFields.clear();
  Src.PointeeBytesRead = 0;

  std::string Param = Src.ParamName.empty()
                          ? "#" + std::to_string(Src.ParamNumber)
                          : Src.ParamName;
  std::string How = Src.Prov == DataflowSource::Exact
                        ? " [exact: " + Src.Method + "]"
                        : " [heuristic: " + Src.Method + "]";
  DWARFDie Object;
  bool HaveObject = false;
  if (Src.Indirect) {
    Object = T;
    HaveObject = true;
  } else {
    DWARFDie Stripped = stripTypedefs(T);
    DWARFDie PointerType;
    if (isPointerLike(Stripped))
      PointerType = Stripped;
    else if (Src.Pieces.size() == 1 && Src.Pieces[0].ValueBit == 0)
      PointerType = findPointerMember(T, Src.Pieces[0].VarBit);
    if (PointerType) {
      Object = getReferencedType(PointerType);
      HaveObject = true;
    }
  }
  if (!HaveObject) {
    Src.Summary = What + " -> through \"" + Param +
                  "\", which is not a pointer in the debug information" + How;
    return Src;
  }

  DataflowSource::AccessInfo Access;
  Access.ObjectType = getTypeName(Object);
  int64_t Lo = 8 * Desc.accessOffset();
  int64_t Hi = Lo + 8 * int64_t(Desc.Size);
  std::optional<uint64_t> ObjectBytes =
      Object ? getTypeByteSize(Object) : std::nullopt;
  int64_t Base = 0;
  if (Lo < 0) {
    // Before the object: a member of an enclosing one, which the pointer's
    // type does not say.
    Access.Outside = true;
  } else if (ObjectBytes && *ObjectBytes && Hi > int64_t(8 * *ObjectBytes)) {
    // Past it: an element of an array of such objects, if the bytes fit one.
    int64_t ElemBits = 8 * *ObjectBytes;
    int64_t Index = Lo / ElemBits;
    if (Index > 0 && Hi <= (Index + 1) * ElemBits) {
      Access.Index = Index;
      Base = Index * ElemBits;
    } else {
      Access.Outside = true;
    }
  }
  if (Object) {
    AccessMemberCollector Collector{Lo - Base, Hi - Base, Access.Members};
    Collector.visit(Object, 0,
                    ObjectBytes ? std::optional<uint64_t>(8 * *ObjectBytes)
                                : std::nullopt,
                    "", 0);
  }
  for (DataflowSource::AccessMember &M : Access.Members) {
    M.Expression =
        getAccessExpression(Param, Src.Indirect, Access.Index, M.Name);
    // Which bits of the value are which bits of memory depends on the byte
    // order; the offsets above are little-endian ones.
    if (!LittleEndian)
      M.ValueBit = M.MemberBit = 0;
  }

  std::string Where;
  for (const DataflowSource::AccessMember &M : Access.Members)
    Where += (Where.empty() ? "" : ", ") + M.Expression +
             (M.Complete ? "" : " (part)");
  if (Where.empty())
    Where = Access.Outside ? "outside \"" + Access.ObjectType +
                                 "\" through \"" + Param + "\""
                           : "\"" + Param + "\"";
  Src.Summary = What + " -> " + Where + How;
  Src.Access = std::move(Access);
  return Src;
}

// A trace-args/trace-ret call site, the source-level frame it reports for,
// and what it observes.
struct DataflowPoint {
  uint64_t Addr;
  // The section of Addr in a relocatable object, else empty.
  std::string Section;
  DataflowKind Kind;
  // The frame the call site belongs to, then every frame it was inlined into,
  // outward.
  SmallVector<DILineInfo, 2> Frames;
  std::optional<DataflowDescriptor> Desc;
  DataflowSource Source;
};

// The name of the function symbol of relocatable object O that holds Addr in
// section SectionIndex, or an empty string.
static std::string getFunctionSymbol(const object::ObjectFile &O,
                                     uint64_t SectionIndex, uint64_t Addr) {
  for (const object::SymbolRef &Sym : O.symbols()) {
    Expected<object::SymbolRef::Type> Type = Sym.getType();
    Expected<object::section_iterator> Sec = Sym.getSection();
    Expected<uint64_t> Start = Sym.getAddress();
    Expected<StringRef> Name = Sym.getName();
    if (!Type || !Sec || !Start || !Name) {
      consumeError(Type.takeError());
      consumeError(Sec.takeError());
      consumeError(Start.takeError());
      consumeError(Name.takeError());
      continue;
    }
    if (*Type != object::SymbolRef::ST_Function || *Sec == O.section_end() ||
        (*Sec)->getIndex() != SectionIndex)
      continue;
    uint64_t Size = isa<object::ELFObjectFileBase>(&O)
                        ? object::ELFSymbolRef(Sym).getSize()
                        : 0;
    if (*Start <= Addr && Addr < *Start + Size)
      return ClDemangle ? demangle(*Name) : Name->str();
  }
  return "";
}

// The frames of Addr in a relocatable object, innermost first. The
// symbolizer's line table lookup takes the section into account, which gives
// the innermost frame's location (Line); its subprogram lookup does not, and
// in a relocatable object can find a function of another section, so the
// function and the inlined frames come from findSubprogram().
static void getSectionFrames(const object::ObjectFile &O, DWARFContext *DICtx,
                             object::SectionedAddress Addr, DILineInfo Line,
                             SmallVectorImpl<DILineInfo> &Frames) {
  auto Name = [](DWARFDie D) {
    const char *N = D.getSubroutineName(DINameKind::LinkageName);
    if (!N)
      return std::string(DILineInfo::BadString);
    return ClDemangle ? demangle(N) : std::string(N);
  };
  Line.FileName = normalizeFilename(Line.FileName);

  DWARFDie Function;
  if (DICtx)
    for (const auto &CU : DICtx->compile_units())
      if ((Function = findSubprogram(
               CU->getUnitDIE(/*ExtractUnitDIEOnly=*/false), Addr)))
        break;
  if (!Function) {
    std::string Sym = getFunctionSymbol(O, Addr.SectionIndex, Addr.Address);
    if (!Sym.empty())
      Line.FunctionName = Sym;
    else if (!Line.FileName.empty() || Line.Line)
      Line.FunctionName = DILineInfo::BadString;
    Frames.push_back(Line);
    return;
  }

  // The scopes holding Addr, outermost first.
  SmallVector<DWARFDie, 4> Scopes{Function};
  getInlinedScopes(Function, Addr.Address, Scopes);

  // Innermost first: each frame is where its scope's code is, which for an
  // outer frame is the call site of the next scope in.
  DILineInfo Frame = Line;
  for (size_t I = Scopes.size(); I-- > 0;) {
    Frame.FunctionName = Name(Scopes[I]);
    Frames.push_back(Frame);
    if (!I)
      break;
    uint32_t CallFile = 0, CallLine = 0, CallColumn = 0, Discriminator = 0;
    Scopes[I].getCallerFrame(CallFile, CallLine, CallColumn, Discriminator);
    Frame = DILineInfo();
    Frame.Line = CallLine;
    Frame.Column = CallColumn;
    DWARFUnit *U = Scopes[I].getDwarfUnit();
    if (const DWARFDebugLine::LineTable *LT = DICtx->getLineTableForUnit(U)) {
      std::string File;
      if (LT->getFileNameByIndex(
              CallFile, U->getCompilationDir(),
              DILineInfoSpecifier::FileLineInfoKind::AbsoluteFilePath, File))
        Frame.FileName = normalizeFilename(File);
    }
  }
}

static std::vector<DataflowPoint>
getDataflowPoints(const std::string &ObjectFile) {
  std::vector<DataflowPoint> Result;
  auto Symbolizer(createSymbolizer());
  // The symbolizer names a function from the symbol table by address alone,
  // which in a relocatable object can be a symbol of another section; there
  // the names come from the debug information, or from a symbol of the
  // section the call is in.
  auto SectionSymbolizer(createSymbolizer(/*UseSymbolTable=*/false));
  Ignorelists Ig;

  visitObjectFiles(ObjectFile, [&](const object::ObjectFile &O) {
    std::map<DataflowAddr, DataflowDescriptor> Descs =
        readDataflowDescriptors(O);
    std::map<DataflowAddr, DataflowSite> Sites;
    getObjectDataflowPoints(O, &Sites, Descs);
    std::unique_ptr<DWARFContext> DICtx = DWARFContext::create(
        O, DWARFContext::ProcessDebugRelocations::Process, nullptr, "",
        WithColor::defaultErrorHandler, WithColor::defaultWarningHandler,
        /*ThreadSafe=*/false);

    for (auto [Key, Site] : Sites) {
      uint64_t Addr = Key.Addr;
      // In a relocatable object the section index tells apart the sections,
      // all of which start at 0.
      bool InSection =
          Key.SectionIndex != object::SectionedAddress::UndefSection;
      auto InliningInfo =
          (InSection ? SectionSymbolizer : Symbolizer)
              ->symbolizeInlinedCode(ObjectFile, {Addr, Key.SectionIndex});
      failIfError(InliningInfo);

      DataflowPoint Point{Addr, "", Site.Kind, {}, std::nullopt, {}};
      if (Key.SectionIndex != object::SectionedAddress::UndefSection) {
        for (object::SectionRef Sec : O.sections()) {
          if (Sec.getIndex() != Key.SectionIndex)
            continue;
          Expected<StringRef> Name = Sec.getName();
          failIfError(Name);
          Point.Section = Name->str();
          break;
        }
      }
      if (InSection) {
        getSectionFrames(O, DICtx.get(), {Addr, Key.SectionIndex},
                         InliningInfo->getNumberOfFrames()
                             ? InliningInfo->getFrame(0)
                             : DILineInfo(),
                         Point.Frames);
      } else {
        for (uint32_t I = 0; I < InliningInfo->getNumberOfFrames(); ++I) {
          DILineInfo Frame = InliningInfo->getFrame(I);
          Frame.FileName = normalizeFilename(Frame.FileName);
          Point.Frames.push_back(Frame);
        }
      }
      // The point belongs to its innermost frame, so that frame decides
      // whether the ignorelist drops it.
      if (!Point.Frames.empty() && Ig.isIgnorelisted(Point.Frames.front()))
        continue;
      // A descriptor of the other kind is not this call's.
      if (auto It = Descs.find({Site.SectionIndex, Site.CallAddr});
          It != Descs.end() &&
          bool(It->second.Flags & DataflowDescriptor::F_Return) ==
              (Site.Kind == DataflowKind::Ret))
        Point.Desc = It->second;
      Point.Source = Site.Kind == DataflowKind::Access && Point.Desc
                         ? resolveAccessSource(
                               DICtx.get(), {Site.CallAddr, Site.SectionIndex},
                               *Point.Desc, O.isLittleEndian())
                         : resolveDataflowSource(
                               DICtx.get(), {Site.CallAddr, Site.SectionIndex},
                               Site.Kind, Point.Desc ? &*Point.Desc : nullptr);
      Result.push_back(std::move(Point));
    }
  });
  return Result;
}

static void writeDataflowFields(json::OStream &W, StringRef Name,
                                const std::vector<DataflowSource::Field> &Fields) {
  W.attributeArray(Name, [&] {
    for (const DataflowSource::Field &F : Fields)
      W.object([&] {
        W.attribute("name", F.F.Name);
        W.attribute("type", F.F.Type);
        W.attribute("bit_offset", int64_t(F.F.BitOffset));
        W.attribute("bit_size", int64_t(F.F.BitSize));
        if (F.ValueBit)
          W.attribute("value_bit_offset", int64_t(*F.ValueBit));
        if (!F.Observed)
          W.attribute("observed", false);
        else if (!F.Complete)
          W.attribute("complete", false);
      });
  });
}

// Output symbolized trace-args/trace-ret call sites in JSON.
// Format:
// {
//   '<binary>' : [
//     {
//       'pc' : '0x<address>',
//       'section' : '<name>',   (relocatable objects: the section of 'pc')
//       'kind' : 'args' | 'ret' | 'access',
//       'frames' : [
//         { 'function' : '<name>', 'file' : '<file>',
//           'line' : <line>, 'column' : <column> },
//         ...  (innermost first)
//       ],
//       'observation' : {            (from the observation descriptor)
//         'ir_arg' : <n>, 'ir_args' : <n>,   (arguments)
//         'element' : <n>, 'element_offset' : <bytes>,  (aggregate elements)
//         'class' : 'integer' | 'pointer' | 'float' | 'vector' | 'object' |
//                   'none',
//         'size' : <bytes>,
//         'flags' : [ 'element', 'in_memory_arg', 'sret_object',
//                     'hidden_args', 'unused', 'pointee', 'access' ],
//         'access' : {                 (access records)
//           'kind' : 'load' | 'store', 'volatile' : true,
//           'atomic' : '<ordering>', 'offset' : <signed bytes>,
//           'access_size' : <bytes>, 'piece' : <n>
//         }
//       },
//       'source' : {
//         'provenance' : 'exact' | 'heuristic' | 'unresolved',
//         'method' : '<how it was resolved, or why it was not>',
//         'summary' : '<one line>',
//         'parameter' : { 'name' : '<name>', 'number' : <1-based> },
//         'type' : '<source type>',
//         'indirect' : true,   (the value is the parameter's address)
//         'pieces' : [ { 'value_bit_offset', 'parameter_bit_offset',
//                        'bit_size' } ],
//         'fields' : [ { 'name', 'type', 'bit_offset', 'bit_size',
//                        'value_bit_offset', 'complete', 'observed' } ],
//         'pointee' : { 'type' : '<type>', 'bytes_read' : <bytes>,
//                       'fields' : [...] },
//         'access' : {                 (access records)
//           'object_type' : '<what the pointer points to>',
//           'index' : <n>,      (in element n of an array of such objects)
//           'outside' : true,   (bytes outside the object, e.g. container_of)
//           'members' : [ { 'name', 'expression', 'type', 'bit_offset',
//                           'bit_size', 'value_bit_offset',
//                           'member_bit_offset', 'overlap_bits',
//                           'complete' } ]
//         }
//       }
//     },
//     ...
//   ]
// }
//
// A field's bit_offset is in the object it is a member of: the parameter or
// return value, the object `val` addresses, or the pointee. A field is
// "complete": false if the observation holds only part of it, and
// "observed": false if it holds none of it: a member of a pointee beyond the
// `bytes_read` the runtime read behind the pointer, or all of a pointee it read
// nothing of.
//
// An access record's members are those its bytes overlap, in the object the
// pointer points to (or the parameter, if the pointer is its address): the
// overlap is bits [value_bit_offset, + overlap_bits) of the value and bits
// [member_bit_offset, + overlap_bits) of the member, "complete": false if that
// is not all of the member. The record is the value of one load or store at
// the time it executed, not the state of the object.
static void symbolizeDataflowPoints(const std::vector<std::string> &ObjFiles,
                                    raw_ostream &OS) {
  // Symbolize everything first, so that a failure does not leave half a JSON
  // document behind.
  std::vector<std::pair<std::string, std::vector<DataflowPoint>>> Points;
  for (const std::string &ObjFile : ObjFiles)
    Points.emplace_back(ObjFile, getDataflowPoints(ObjFile));

  json::OStream W(OS, 2);
  W.object([&] {
    for (const auto &FileAndPoints : Points) {
      W.attributeArray(FileAndPoints.first, [&] {
        for (const DataflowPoint &Point : FileAndPoints.second) {
          W.object([&] {
            W.attribute("pc", "0x" + utohexstr(Point.Addr, /*LowerCase=*/true));
            if (!Point.Section.empty())
              W.attribute("section", Point.Section);
            W.attribute("kind", getDataflowKindName(Point.Kind));
            W.attributeArray("frames", [&] {
              for (const DILineInfo &Frame : Point.Frames) {
                W.object([&] {
                  W.attribute("function", Frame.FunctionName);
                  W.attribute("file", Frame.FileName);
                  W.attribute("line", Frame.Line);
                  W.attribute("column", Frame.Column);
                });
              }
            });
            if (const auto &D = Point.Desc) {
              W.attributeObject("observation", [&] {
                if (Point.Kind != DataflowKind::Ret) {
                  W.attribute("ir_arg", D->IRArg);
                  W.attribute("ir_args", D->IRArgCount);
                }
                if (D->isAccess()) {
                  W.attributeObject("access", [&] {
                    W.attribute("kind",
                                D->AccessKind & DataflowDescriptor::AK_Store
                                    ? "store"
                                    : "load");
                    if (D->AccessKind & DataflowDescriptor::AK_Volatile)
                      W.attribute("volatile", true);
                    if (D->AccessKind & DataflowDescriptor::AK_Atomic)
                      W.attribute("atomic",
                                  getAtomicOrderingName(D->accessOrdering()));
                    W.attribute("offset", D->accessOffset());
                    W.attribute("access_size", D->AccessSize);
                    W.attribute("piece", D->Element);
                  });
                } else if (D->Flags & DataflowDescriptor::F_Element) {
                  W.attribute("element", D->Element);
                  W.attribute("element_offset", D->ElementOffset);
                }
                W.attribute("class", getDataflowClassName(D->Class));
                W.attribute("size", D->Size);
                W.attributeArray("flags", [&] {
                  if (D->Flags & DataflowDescriptor::F_Element)
                    W.value("element");
                  if (D->Flags & DataflowDescriptor::F_InMemoryArg)
                    W.value("in_memory_arg");
                  if (D->Flags & DataflowDescriptor::F_SRetObject)
                    W.value("sret_object");
                  if (D->Flags & DataflowDescriptor::F_HiddenArgs)
                    W.value("hidden_args");
                  if (D->Flags & DataflowDescriptor::F_Unused)
                    W.value("unused");
                  if (D->Flags & DataflowDescriptor::F_Pointee)
                    W.value("pointee");
                  if (D->isAccess())
                    W.value("access");
                });
              });
            }
            const DataflowSource &Src = Point.Source;
            W.attributeObject("source", [&] {
              W.attribute("provenance", getProvenanceName(Src.Prov));
              W.attribute("method", Src.Method);
              W.attribute("summary", Src.Summary);
              if (Src.Prov == DataflowSource::Unresolved)
                return;
              if (Point.Kind != DataflowKind::Ret)
                W.attributeObject("parameter", [&] {
                  W.attribute("name", Src.ParamName);
                  if (Src.ParamNumber)
                    W.attribute("number", int64_t(Src.ParamNumber));
                  if (Src.Artificial)
                    W.attribute("artificial", true);
                });
              W.attribute("type", Src.TypeName);
              if (Src.Indirect)
                W.attribute("indirect", true);
              if (Point.Kind != DataflowKind::Ret && !Src.Indirect &&
                  !Src.Pieces.empty())
                W.attributeArray("pieces", [&] {
                  for (const DataflowMapPiece &P : Src.Pieces)
                    W.object([&] {
                      W.attribute("value_bit_offset", int64_t(P.ValueBit));
                      W.attribute("parameter_bit_offset", int64_t(P.VarBit));
                      W.attribute("bit_size", int64_t(P.Bits));
                    });
                });
              if (!Src.Fields.empty()) {
                writeDataflowFields(W, "fields", Src.Fields);
                if (!Src.FieldsProvenance.empty())
                  W.attribute("fields_provenance", Src.FieldsProvenance);
              }
              if (Src.PointeeType) {
                W.attributeObject("pointee", [&] {
                  W.attribute("type", *Src.PointeeType);
                  W.attribute("bytes_read", int64_t(Src.PointeeBytesRead));
                  writeDataflowFields(W, "fields", Src.PointeeFields);
                });
              }
              if (const auto &A = Src.Access) {
                W.attributeObject("access", [&] {
                  W.attribute("object_type", A->ObjectType);
                  if (A->Index)
                    W.attribute("index", int64_t(*A->Index));
                  if (A->Outside)
                    W.attribute("outside", true);
                  W.attributeArray("members", [&] {
                    for (const DataflowSource::AccessMember &M : A->Members)
                      W.object([&] {
                        W.attribute("name", M.Name);
                        W.attribute("expression", M.Expression);
                        W.attribute("type", M.Type);
                        W.attribute("bit_offset", int64_t(M.BitOffset));
                        W.attribute("bit_size", int64_t(M.BitSize));
                        W.attribute("value_bit_offset", int64_t(M.ValueBit));
                        if (M.MemberBit)
                          W.attribute("member_bit_offset",
                                      int64_t(M.MemberBit));
                        W.attribute("overlap_bits", int64_t(M.Bits));
                        if (!M.Complete)
                          W.attribute("complete", false);
                      });
                  });
                });
              }
            });
          });
        }
      });
    }
  });
  OS << "\n";
}

static ErrorOr<bool> isCoverageFile(const std::string &FileName) {
  auto ShortFileName = llvm::sys::path::filename(FileName);
  if (!SancovFileRegex.match(ShortFileName))
    return false;

  ErrorOr<std::unique_ptr<MemoryBuffer>> BufOrErr =
      MemoryBuffer::getFile(FileName);
  if (!BufOrErr) {
    errs() << "Warning: " << BufOrErr.getError().message() << "("
           << BufOrErr.getError().value()
           << "), filename: " << llvm::sys::path::filename(FileName) << "\n";
    return BufOrErr.getError();
  }
  std::unique_ptr<MemoryBuffer> Buf = std::move(BufOrErr.get());
  if (Buf->getBufferSize() < 8) {
    return false;
  }
  const FileHeader *Header =
      reinterpret_cast<const FileHeader *>(Buf->getBufferStart());
  return Header->Magic == BinCoverageMagic;
}

static bool isSymbolizedCoverageFile(const std::string &FileName) {
  auto ShortFileName = llvm::sys::path::filename(FileName);
  return SymcovFileRegex.match(ShortFileName);
}

static std::unique_ptr<SymbolizedCoverage>
symbolize(const RawCoverage &Data, const std::string ObjectFile) {
  auto Coverage = std::make_unique<SymbolizedCoverage>();

  ErrorOr<std::unique_ptr<MemoryBuffer>> BufOrErr =
      MemoryBuffer::getFile(ObjectFile);
  failIfError(BufOrErr);
  SHA1 Hasher;
  Hasher.update((*BufOrErr)->getBuffer());
  Coverage->BinaryHash = toHex(Hasher.final());

  Ignorelists Ig;
  auto Symbolizer(createSymbolizer());

  for (uint64_t Addr : *Data.Addrs) {
    // TODO: it would be neccessary to set proper section index here.
    // object::SectionedAddress::UndefSection works for only absolute addresses.
    auto LineInfo = Symbolizer->symbolizeCode(
        ObjectFile, {Addr, object::SectionedAddress::UndefSection});
    failIfError(LineInfo);
    if (Ig.isIgnorelisted(*LineInfo))
      continue;

    Coverage->CoveredIds.insert(utohexstr(Addr, true));
  }

  std::set<uint64_t> AllAddrs = findCoveragePointAddrs(ObjectFile);
  if (!llvm::includes(AllAddrs, *Data.Addrs)) {
    fail("Coverage points in binary and .sancov file do not match.");
  }
  Coverage->Points = getCoveragePoints(ObjectFile, AllAddrs, *Data.Addrs);
  return Coverage;
}

struct FileFn {
  bool operator<(const FileFn &RHS) const {
    return std::tie(FileName, FunctionName) <
           std::tie(RHS.FileName, RHS.FunctionName);
  }

  std::string FileName;
  std::string FunctionName;
};

static std::set<FileFn>
computeFunctions(const std::vector<CoveragePoint> &Points) {
  std::set<FileFn> Fns;
  for (const auto &Point : Points) {
    for (const auto &Loc : Point.Locs) {
      Fns.insert(FileFn{Loc.FileName, Loc.FunctionName});
    }
  }
  return Fns;
}

static std::set<FileFn>
computeNotCoveredFunctions(const SymbolizedCoverage &Coverage) {
  auto Fns = computeFunctions(Coverage.Points);

  for (const auto &Point : Coverage.Points) {
    if (Coverage.CoveredIds.find(Point.Id) == Coverage.CoveredIds.end())
      continue;

    for (const auto &Loc : Point.Locs) {
      Fns.erase(FileFn{Loc.FileName, Loc.FunctionName});
    }
  }

  return Fns;
}

static std::set<FileFn>
computeCoveredFunctions(const SymbolizedCoverage &Coverage) {
  std::set<FileFn> Result;

  for (const auto &Point : Coverage.Points) {
    if (Coverage.CoveredIds.find(Point.Id) == Coverage.CoveredIds.end())
      continue;

    for (const auto &Loc : Point.Locs) {
      Result.insert(FileFn{Loc.FileName, Loc.FunctionName});
    }
  }

  return Result;
}

typedef std::map<FileFn, std::pair<uint32_t, uint32_t>> FunctionLocs;
// finds first location in a file for each function.
static FunctionLocs resolveFunctions(const SymbolizedCoverage &Coverage,
                                     const std::set<FileFn> &Fns) {
  FunctionLocs Result;
  for (const auto &Point : Coverage.Points) {
    for (const auto &Loc : Point.Locs) {
      FileFn Fn = FileFn{Loc.FileName, Loc.FunctionName};
      if (Fns.find(Fn) == Fns.end())
        continue;

      auto P = std::make_pair(Loc.Line, Loc.Column);
      auto [It, Inserted] = Result.try_emplace(Fn, P);
      if (!Inserted && It->second > P)
        It->second = P;
    }
  }
  return Result;
}

static void printFunctionLocs(const FunctionLocs &FnLocs, raw_ostream &OS) {
  for (const auto &P : FnLocs) {
    OS << stripPathPrefix(P.first.FileName) << ":" << P.second.first << " "
       << P.first.FunctionName << "\n";
  }
}
CoverageStats computeStats(const SymbolizedCoverage &Coverage) {
  CoverageStats Stats = {Coverage.Points.size(), Coverage.CoveredIds.size(),
                         computeFunctions(Coverage.Points).size(),
                         computeCoveredFunctions(Coverage).size()};
  return Stats;
}

// Print list of covered functions.
// Line format: <file_name>:<line> <function_name>
static void printCoveredFunctions(const SymbolizedCoverage &CovData,
                                  raw_ostream &OS) {
  auto CoveredFns = computeCoveredFunctions(CovData);
  printFunctionLocs(resolveFunctions(CovData, CoveredFns), OS);
}

// Print list of not covered functions.
// Line format: <file_name>:<line> <function_name>
static void printNotCoveredFunctions(const SymbolizedCoverage &CovData,
                                     raw_ostream &OS) {
  auto NotCoveredFns = computeNotCoveredFunctions(CovData);
  printFunctionLocs(resolveFunctions(CovData, NotCoveredFns), OS);
}

// Read list of files and merges their coverage info.
static void readAndPrintRawCoverage(const std::vector<std::string> &FileNames,
                                    raw_ostream &OS) {
  for (const auto &FileName : FileNames) {
    auto Cov = RawCoverage::read(FileName);
    if (!Cov)
      continue;
    OS << *Cov.get();
  }
}

static const char *bitnessToString(uint32_t Bitness) {
  switch (Bitness) {
  case Bitness64:
    return "64-bit";
  case Bitness32:
    return "32-bit";
  default:
    fail("Unsupported bitness: " + std::to_string(Bitness));
    return nullptr;
  }
}

// Warn if two file headers have different bitness.
static void warnIfDifferentBitness(const FileHeader &Header1,
                                   const FileHeader &Header2,
                                   const std::string &File1Desc,
                                   const std::string &File2Desc) {
  if (Header1.Bitness != Header2.Bitness) {
    errs() << "WARNING: Input files have different bitness (" << File1Desc
           << ": " << bitnessToString(Header1.Bitness) << ", " << File2Desc
           << ": " << bitnessToString(Header2.Bitness)
           << "). Using bitness from " << File1Desc << ".\n";

    if (Header1.Bitness == Bitness32 && Header2.Bitness == Bitness64) {
      errs() << "WARNING: 64-bit addresses will be truncated to 32 bits. "
             << "This may result in data loss.\n";
    }
  }
}

// Compute difference between two coverage files (A - B) and write to output
// file.
static void diffRawCoverage(const std::string &FileA, const std::string &FileB,
                            const std::string &OutputFile) {
  auto CovA = RawCoverage::read(FileA);
  failIfError(CovA);

  auto CovB = RawCoverage::read(FileB);
  failIfError(CovB);

  const FileHeader &HeaderA = CovA.get()->Header;
  const FileHeader &HeaderB = CovB.get()->Header;

  warnIfDifferentBitness(HeaderA, HeaderB, FileA, FileB);

  // Compute A - B
  auto DiffAddrs = std::make_unique<std::set<uint64_t>>();
  std::set_difference(CovA.get()->Addrs->begin(), CovA.get()->Addrs->end(),
                      CovB.get()->Addrs->begin(), CovB.get()->Addrs->end(),
                      std::inserter(*DiffAddrs, DiffAddrs->end()));

  RawCoverage DiffCov(std::move(DiffAddrs), HeaderA);
  RawCoverage::write(OutputFile, DiffCov);
}

// Compute union of multiple coverage files and write to output file.
static void unionRawCoverage(const std::vector<std::string> &InputFiles,
                             const std::string &OutputFile) {
  failIf(InputFiles.empty(), "union action requires at least one input file");

  // Read the first file to get the header and initial coverage
  auto UnionCov = RawCoverage::read(InputFiles[0]);
  failIfError(UnionCov);

  const FileHeader &UnionHeader = UnionCov.get()->Header;

  for (size_t I = 1; I < InputFiles.size(); ++I) {
    auto Cov = RawCoverage::read(InputFiles[I]);
    failIfError(Cov);

    const FileHeader &CurHeader = Cov.get()->Header;

    warnIfDifferentBitness(UnionHeader, CurHeader, InputFiles[0],
                           InputFiles[I]);

    UnionCov.get()->Addrs->insert(Cov.get()->Addrs->begin(),
                                  Cov.get()->Addrs->end());
  }

  RawCoverage::write(OutputFile, *UnionCov.get());
}

static std::unique_ptr<SymbolizedCoverage>
merge(const std::vector<std::unique_ptr<SymbolizedCoverage>> &Coverages) {
  if (Coverages.empty())
    return nullptr;

  auto Result = std::make_unique<SymbolizedCoverage>();

  for (size_t I = 0; I < Coverages.size(); ++I) {
    const SymbolizedCoverage &Coverage = *Coverages[I];
    std::string Prefix;
    if (Coverages.size() > 1) {
      // prefix is not needed when there's only one file.
      Prefix = utostr(I);
    }

    for (const auto &Id : Coverage.CoveredIds) {
      Result->CoveredIds.insert(Prefix + Id);
    }

    for (const auto &CovPoint : Coverage.Points) {
      CoveragePoint NewPoint(CovPoint);
      NewPoint.Id = Prefix + CovPoint.Id;
      Result->Points.push_back(NewPoint);
    }
  }

  if (Coverages.size() == 1) {
    Result->BinaryHash = Coverages[0]->BinaryHash;
  }

  return Result;
}

static std::unique_ptr<SymbolizedCoverage>
readSymbolizeAndMergeCmdArguments(std::vector<std::string> FileNames) {
  std::vector<std::unique_ptr<SymbolizedCoverage>> Coverages;

  {
    // Short name => file name.
    std::map<std::string, std::string, std::less<>> ObjFiles;
    std::string FirstObjFile;
    std::set<std::string> CovFiles;

    // Partition input values into coverage/object files.
    for (const auto &FileName : FileNames) {
      if (isSymbolizedCoverageFile(FileName)) {
        Coverages.push_back(SymbolizedCoverage::read(FileName));
      }

      auto ErrorOrIsCoverage = isCoverageFile(FileName);
      if (!ErrorOrIsCoverage)
        continue;
      if (ErrorOrIsCoverage.get()) {
        CovFiles.insert(FileName);
      } else {
        auto ShortFileName = llvm::sys::path::filename(FileName);
        if (ObjFiles.find(ShortFileName) != ObjFiles.end()) {
          fail("Duplicate binary file with a short name: " + ShortFileName);
        }

        ObjFiles[std::string(ShortFileName)] = FileName;
        if (FirstObjFile.empty())
          FirstObjFile = FileName;
      }
    }

    SmallVector<StringRef, 2> Components;

    // Object file => list of corresponding coverage file names.
    std::map<std::string, std::vector<std::string>> CoverageByObjFile;
    for (const auto &FileName : CovFiles) {
      auto ShortFileName = llvm::sys::path::filename(FileName);
      auto Ok = SancovFileRegex.match(ShortFileName, &Components);
      if (!Ok) {
        fail("Can't match coverage file name against "
             "<module_name>.<pid>.sancov pattern: " +
             FileName);
      }

      auto Iter = ObjFiles.find(Components[1]);
      if (Iter == ObjFiles.end()) {
        fail("Object file for coverage not found: " + FileName);
      }

      CoverageByObjFile[Iter->second].push_back(FileName);
    };

    for (const auto &Pair : ObjFiles) {
      auto FileName = Pair.second;
      if (CoverageByObjFile.find(FileName) == CoverageByObjFile.end())
        errs() << "WARNING: No coverage file for " << FileName << "\n";
    }

    // Read raw coverage and symbolize it.
    for (const auto &Pair : CoverageByObjFile) {
      if (findSanitizerCovFunctions(Pair.first).empty()) {
        errs()
            << "WARNING: Ignoring " << Pair.first
            << " and its coverage because  __sanitizer_cov* functions were not "
               "found.\n";
        continue;
      }

      for (const std::string &CoverageFile : Pair.second) {
        auto DataOrError = RawCoverage::read(CoverageFile);
        failIfError(DataOrError);
        Coverages.push_back(symbolize(*DataOrError.get(), Pair.first));
      }
    }
  }

  return merge(Coverages);
}

} // namespace

static void parseArgs(int Argc, char **Argv) {
  SancovOptTable Tbl;
  llvm::BumpPtrAllocator A;
  llvm::StringSaver Saver{A};
  opt::InputArgList Args =
      Tbl.parseArgs(Argc, Argv, OPT_UNKNOWN, Saver, [&](StringRef Msg) {
        llvm::errs() << Msg << '\n';
        std::exit(1);
      });

  if (Args.hasArg(OPT_help)) {
    Tbl.printHelp(
        llvm::outs(),
        "sancov [options] <action> <binary files...> <.sancov files...> "
        "<.symcov files...>",
        "Sanitizer Coverage Processing Tool (sancov)\n\n"
        "  This tool can extract various coverage-related information from: \n"
        "  coverage-instrumented binary files, raw .sancov files and their "
        "symbolized .symcov version.\n"
        "  Depending on chosen action the tool expects different input files:\n"
        "    -print-coverage-pcs     - coverage-instrumented binary files\n"
        "    -print-dataflow-pcs     - trace-args/trace-ret instrumented "
        "binary files\n"
        "    -symbolize-dataflow     - trace-args/trace-ret instrumented "
        "binary files\n"
        "    -print-coverage         - .sancov files\n"
        "    -diff                   - two .sancov files & --output option\n"
        "    -union                  - one or more .sancov files & --output "
        "option\n"
        "    <other actions>         - .sancov files & corresponding binary "
        "files, .symcov files\n");
    std::exit(0);
  }

  if (Args.hasArg(OPT_version)) {
    cl::PrintVersionMessage();
    std::exit(0);
  }

  if (Args.hasMultipleArgs(OPT_action_grp)) {
    fail("Only one action option is allowed");
  }

  for (const opt::Arg *A : Args.filtered(OPT_INPUT)) {
    ClInputFiles.emplace_back(A->getValue());
  }

  if (const llvm::opt::Arg *A = Args.getLastArg(OPT_action_grp)) {
    switch (A->getOption().getID()) {
    case OPT_print:
      Action = ActionType::PrintAction;
      break;
    case OPT_diff:
      Action = ActionType::DiffAction;
      break;
    case OPT_union_files:
      Action = ActionType::UnionAction;
      break;
    case OPT_printCoveragePcs:
      Action = ActionType::PrintCovPointsAction;
      break;
    case OPT_printDataflowPcs:
      Action = ActionType::PrintDataflowPointsAction;
      break;
    case OPT_symbolizeDataflow:
      Action = ActionType::SymbolizeDataflowAction;
      break;
    case OPT_coveredFunctions:
      Action = ActionType::CoveredFunctionsAction;
      break;
    case OPT_notCoveredFunctions:
      Action = ActionType::NotCoveredFunctionsAction;
      break;
    case OPT_printCoverageStats:
      Action = ActionType::StatsAction;
      break;
    case OPT_htmlReport:
      Action = ActionType::HtmlReportAction;
      break;
    case OPT_symbolize:
      Action = ActionType::SymbolizeAction;
      break;
    case OPT_merge:
      Action = ActionType::MergeAction;
      break;
    default:
      fail("Invalid Action");
    }
  }

  ClDemangle = Args.hasFlag(OPT_demangle, OPT_no_demangle, true);
  ClSkipDeadFiles = Args.hasFlag(OPT_skipDeadFiles, OPT_no_skipDeadFiles, true);
  ClUseDefaultIgnorelist =
      Args.hasFlag(OPT_useDefaultIgnoreList, OPT_no_useDefaultIgnoreList, true);

  ClStripPathPrefix = Args.getLastArgValue(OPT_stripPathPrefix_EQ);
  ClIgnorelist = Args.getLastArgValue(OPT_ignorelist_EQ);
  ClOutputFile = Args.getLastArgValue(OPT_output_EQ);
}

int sancov_main(int Argc, char **Argv, const llvm::ToolContext &) {
  llvm::InitializeAllTargetInfos();
  llvm::InitializeAllTargetMCs();
  llvm::InitializeAllDisassemblers();

  parseArgs(Argc, Argv);

  // -print doesn't need object files.
  if (Action == PrintAction) {
    readAndPrintRawCoverage(ClInputFiles, outs());
    return 0;
  }
  if (Action == DiffAction) {
    // -diff requires exactly 2 input files and an output file.
    failIf(ClInputFiles.size() != 2,
           "diff action requires exactly 2 input sancov files");
    failIf(
        ClOutputFile.empty(),
        "diff action requires --output option to specify output sancov file");
    diffRawCoverage(ClInputFiles[0], ClInputFiles[1], ClOutputFile);
    return 0;
  }
  if (Action == UnionAction) {
    // -union requires at least 1 input file and an output file.
    failIf(ClInputFiles.empty(),
           "union action requires at least one input sancov file");
    failIf(
        ClOutputFile.empty(),
        "union action requires --output option to specify output sancov file");
    unionRawCoverage(ClInputFiles, ClOutputFile);
    return 0;
  }
  if (Action == PrintCovPointsAction) {
    // -print-coverage-points doesn't need coverage files.
    for (const std::string &ObjFile : ClInputFiles) {
      printCovPoints(ObjFile, outs());
    }
    return 0;
  }
  if (Action == PrintDataflowPointsAction) {
    // -print-dataflow-pcs doesn't need coverage files.
    for (const std::string &ObjFile : ClInputFiles)
      printDataflowPoints(ObjFile, outs());
    return 0;
  }
  if (Action == SymbolizeDataflowAction) {
    // -symbolize-dataflow doesn't need coverage files.
    symbolizeDataflowPoints(ClInputFiles, outs());
    return 0;
  }

  auto Coverage = readSymbolizeAndMergeCmdArguments(ClInputFiles);
  failIf(!Coverage, "No valid coverage files given.");

  switch (Action) {
  case CoveredFunctionsAction: {
    printCoveredFunctions(*Coverage, outs());
    return 0;
  }
  case NotCoveredFunctionsAction: {
    printNotCoveredFunctions(*Coverage, outs());
    return 0;
  }
  case StatsAction: {
    outs() << computeStats(*Coverage);
    return 0;
  }
  case MergeAction:
  case SymbolizeAction: { // merge & symbolize are synonims.
    json::OStream W(outs(), 2);
    W << *Coverage;
    return 0;
  }
  case HtmlReportAction:
    errs() << "-html-report option is removed: "
              "use -symbolize & coverage-report-server.py instead\n";
    return 1;
  case DiffAction:
  case UnionAction:
  case PrintAction:
  case PrintCovPointsAction:
  case PrintDataflowPointsAction:
  case SymbolizeDataflowAction:
    llvm_unreachable("unsupported action");
  }

  return 0;
}

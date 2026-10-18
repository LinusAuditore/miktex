/**
 * @file util.cpp
 * @author Christian Schenk
 * @briefUtility functions (Unix)
 *
 * @copyright Copyright © 1996-2023 Christian Schenk
 *
 * This file is part of the MiKTeX Core Library.
 *
 * The MiKTeX Core Library is licensed under GNU General Public License version
 * 2 or any later version.
 */

#include "config.h"

#include <unistd.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#if defined(HAVE_SYS_UTSNAME_H)
#include <sys/utsname.h>
#endif

#include <fmt/format.h>
#include <fmt/ostream.h>

#include <miktex/Core/Directory>
#if defined(__APPLE__)
#include <miktex/Core/DirectoryLister>
#endif
#include <miktex/Core/File>
#include <miktex/Util/PathName>
#include <miktex/Util/StringUtil>
#include <miktex/Trace/Trace>
#include <miktex/Trace/TraceStream>

#include "internal.h"

#include "Session/SessionImpl.h"

using namespace std;

using namespace MiKTeX::Configuration;
using namespace MiKTeX::Core;
using namespace MiKTeX::Trace;
using namespace MiKTeX::Util;

string Utils::GetOSVersionString()
{
    string version;
#if defined(HAVE_UNAME_SYSCALL)
    struct utsname buf;
    if (uname(&buf) < 0)
    {
        MIKTEX_FATAL_CRT_ERROR("uname");
    }
    version = buf.sysname;
    version += ' ';
    version += buf.release;
    version += ' ';
    version += buf.version;
    version += ' ';
    version += buf.machine;
#else
#warning Unimplemented : Utils::GetOSVersionString
    version = "UnkOS 0.1";
#endif
    return version;
}

void Utils::SetEnvironmentString(const string& valueName, const string& value)
{
    string oldValue;
    if (::GetEnvironmentString(valueName, oldValue) && oldValue == value)
    {
        return;
    }
    auto trace_config = TraceStream::Open(MIKTEX_TRACE_CONFIG);
    trace_config->WriteLine("core", fmt::format(T_("setting env {0}={1}"), valueName, value));
    if (setenv(valueName.c_str(), value.c_str(), 1) != 0)
    {
        MIKTEX_FATAL_CRT_ERROR_2("setenv", "name", valueName);
    }
}

void Utils::RemoveEnvironmentString(const string& valueName)
{
    auto trace_config = TraceStream::Open(MIKTEX_TRACE_CONFIG);
    trace_config->WriteLine("core", fmt::format(T_("unsetting env {0}"), valueName));
    if (unsetenv(valueName.c_str()) != 0)
    {
        MIKTEX_FATAL_CRT_ERROR_2("unsetenv", "name", valueName);
    }
}

void Utils::CheckHeap()
{
}

void Utils::ShowWebPage(const string& url)
{
    UNIMPLEMENTED();
}

bool Utils::SupportsHardLinks(const PathName &path)
{
    return true;
}

#if defined(__APPLE__)
// The lines which enclose the block that CheckPath() appends to a shell
// start-up file.
static const char* const PATH_BLOCK_BEGIN = "# >>> MiKTeX >>>";
static const char* const PATH_BLOCK_END = "# <<< MiKTeX <<<";

// The path_helper(8) file which CheckPath() writes in admin mode.
static const char* const PATHS_D_FILE = "/etc/paths.d/miktex";

static string QuoteForShell(const string& s)
{
    string result = "'";
    for (const char& ch : s)
    {
        if (ch == '\'')
        {
            result += "'\\''";
        }
        else
        {
            result += ch;
        }
    }
    result += '\'';
    return result;
}

static bool IsInSearchPath(const string& searchPath, const PathName& dir)
{
    string newSearchPath;
    bool competition;
    return !FixProgramSearchPath(searchPath, dir, false, newSearchPath, competition);
}

// Get the directories which path_helper(8) puts into the PATH of a login
// shell, i.e., the lines of /etc/paths and of the files in /etc/paths.d.
static string GetPathHelperSearchPath()
{
    vector<PathName> files{ PathName("/etc/paths") };
    PathName pathsDir("/etc/paths.d");
    if (Directory::Exists(pathsDir))
    {
        unique_ptr<DirectoryLister> lister = DirectoryLister::Open(pathsDir);
        DirectoryEntry entry;
        while (lister->GetNext(entry))
        {
            if (!entry.isDirectory)
            {
                files.push_back(pathsDir / entry.name);
            }
        }
        lister->Close();
    }
    string searchPath;
    for (const PathName& file : files)
    {
        // path_helper(8) skips files it cannot read, too
        if (!File::Exists(file) || access(file.GetData(), R_OK) != 0)
        {
            continue;
        }
        ifstream stream = File::CreateInputStream(file);
        string line;
        while (std::getline(stream, line))
        {
            while (!line.empty() && (line.back() == ' ' || line.back() == '\t' || line.back() == '\r'))
            {
                line.pop_back();
            }
            if (line.empty())
            {
                continue;
            }
            if (!searchPath.empty())
            {
                searchPath += PathNameUtil::PathNameDelimiter;
            }
            searchPath += line;
        }
    }
    return searchPath;
}

static bool HasPathBlock(const PathName& profile, const string& casePattern)
{
    if (!File::Exists(profile))
    {
        return false;
    }
    ifstream stream = File::CreateInputStream(profile);
    string line;
    while (std::getline(stream, line))
    {
        if (line.find(casePattern) != string::npos)
        {
            return true;
        }
    }
    return false;
}
#endif

bool Utils::CheckPath(bool repair)
{
#if defined(__APPLE__)
    shared_ptr<Session> session = MIKTEX_SESSION();

    try
    {
        PathName linkTargetDirectory = session->GetSpecialPath(SpecialPath::LinkTargetDirectory);

        // Okay if a new login shell finds the directory.  Its position is
        // not checked: if another TeX system comes first, it stays first.
        // The PATH of this process counts for the user only: it does not
        // tell whether other users get the directory.
        string envPath;
        if (!Directory::Exists(linkTargetDirectory)
            || (!session->IsAdminMode() && Utils::GetEnvironmentString("PATH", envPath) && IsInSearchPath(envPath, linkTargetDirectory))
            || IsInSearchPath(GetPathHelperSearchPath(), linkTargetDirectory))
        {
            return true;
        }

        if (session->IsAdminMode())
        {
            if (!repair)
            {
                SESSION_IMPL()->trace_error->WriteLine("core", TraceLevel::Error, fmt::format(T_("{0} is not in the system PATH"), Q_(linkTargetDirectory)));
                return false;
            }
            ofstream stream = File::CreateOutputStream(PathName(PATHS_D_FILE));
            stream << linkTargetDirectory.ToString() << "\n";
            stream.close();
            SESSION_IMPL()->trace_config->WriteLine("core", TraceLevel::Info, fmt::format(T_("added {0} to the system PATH ({1})"), Q_(linkTargetDirectory), PATHS_D_FILE));
            return true;
        }

        if (session->RunningAsAdministrator())
        {
            // do not create root-owned files in the home directory
            SESSION_IMPL()->trace_error->WriteLine("core", TraceLevel::Error, fmt::format(T_("{0} is not in the PATH; not modifying shell start-up files because running with root privileges"), Q_(linkTargetDirectory)));
            return false;
        }

        PathName homeDirectory = GetHomeDirectory();
        vector<PathName> profiles{ homeDirectory / ".zprofile" };
        if (File::Exists(homeDirectory / ".bash_profile"))
        {
            profiles.push_back(homeDirectory / ".bash_profile");
        }
        string quotedDirectory = QuoteForShell(linkTargetDirectory.ToString());
        string casePattern = "*:" + quotedDirectory + ":*) ;;";
        bool pathOkay = true;
        for (const PathName& profile : profiles)
        {
            if (HasPathBlock(profile, casePattern))
            {
                continue;
            }
            if (!repair)
            {
                SESSION_IMPL()->trace_error->WriteLine("core", TraceLevel::Error, fmt::format(T_("{0} does not add {1} to the PATH"), Q_(profile), Q_(linkTargetDirectory)));
                pathOkay = false;
                continue;
            }
            ofstream stream = File::CreateOutputStream(profile, ios_base::app);
            stream << "\n"
                << PATH_BLOCK_BEGIN << "\n"
                << "# Added by MiKTeX: make the MiKTeX commands available in new shells.\n"
                << "case \":${PATH}:\" in\n"
                << "    " << casePattern << "\n"
                << "    *) export PATH=\"${PATH:+${PATH}:}\"" << quotedDirectory << " ;;\n"
                << "esac\n"
                << PATH_BLOCK_END << "\n";
            stream.close();
            SESSION_IMPL()->trace_config->WriteLine("core", TraceLevel::Info, fmt::format(T_("added {0} to the PATH in {1}"), Q_(linkTargetDirectory), Q_(profile)));
        }
        return pathOkay;
    }
    catch (const exception& e)
    {
        SESSION_IMPL()->trace_error->WriteLine("core", TraceLevel::Error, fmt::format(T_("the PATH could not be modified: {0}"), e.what()));
        return false;
    }
#else
#if 1
    // TODO
    if (repair)
    {
        UNIMPLEMENTED();
    }
#endif

    shared_ptr<Session> session = MIKTEX_SESSION();

    string envPath;
    if (!Utils::GetEnvironmentString("PATH", envPath))
    {
        return false;
    }

    PathName linkTargetDirectory = session->GetSpecialPath(SpecialPath::LinkTargetDirectory);

    string repairedPath;
    bool pathCompetition;

    bool pathOkay = !Directory::Exists(linkTargetDirectory) || !FixProgramSearchPath(envPath, linkTargetDirectory, true, repairedPath, pathCompetition);

    bool repaired = false;

    if (!pathOkay && !repair)
    {
        SESSION_IMPL()->trace_error->WriteLine("core", T_("Something is wrong with the PATH:"));
        SESSION_IMPL()->trace_error->WriteLine("core", envPath.c_str());
    }
    else if (!pathOkay && repair)
    {
        SESSION_IMPL()->trace_error->WriteLine("core", T_("Setting new PATH:"));
        SESSION_IMPL()->trace_error->WriteLine("core", repairedPath.c_str());
        envPath = repairedPath;
        if (session->IsAdminMode())
        {
            // TODO: edit system configuration
        }
        else
        {
            // TODO: edit user configuration
        }
        pathOkay = true;
        repaired = true;
    }
    return repaired || pathOkay;
#endif
}

PathName Utils::GetExe()
{
#if defined(__APPLE__)
    CharBuffer<char> buf;
    uint32_t bufSize = buf.GetCapacity();
    if (_NSGetExecutablePath(buf.GetData(), &bufSize) < 0)
    {
        buf.Reserve(bufSize);
        if (_NSGetExecutablePath(buf.GetData(), &bufSize) != 0)
        {
            MIKTEX_UNEXPECTED();
        }
    }
    return PathName(buf.GetData());
#else
    return File::ReadSymbolicLink(PathName("/proc/self/exe"));
#endif
}

string Utils::GetExeName()
{
#if defined(__APPLE__)
    return GetExe().GetFileNameWithoutExtension().ToString();
#else
    ifstream cmdline = File::CreateInputStream(PathName("/proc/self/comm"));
    string argv0;
    char ch;
    while (cmdline.get(ch) && ch != '\n' && ch != 0)
    {
        argv0 += ch;
    }
    cmdline.close();
    return PathName(argv0).GetFileNameWithoutExtension().ToString();
#endif
}

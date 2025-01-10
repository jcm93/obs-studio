#include "log.hpp"
#include "obs-app.hpp"


struct OBSLogger logger;

void *loggerThread() {
  while (true) {
    auto timeout = std::chrono::milliseconds(100);
    std::unique_lock<std::mutex> lock(logger.newMutex);
    if(_logger.queueHasThingsCondition.wait_for(lock, timeout, [&] { return logger.queueHasThings.load(); })) {
      logger.queueMutex.lock();
      LogMessage message = logger.messageQueue.front();
      logger.messageQueue.pop();
      logger.queueMutex.unlock();
      doLogAction(message);
    }
  }
}

static void create_log_file(fstream &logFile)
{
  stringstream dst;

  get_last_log(false, "obs-studio/logs", lastLogFile);
#ifdef _WIN32
  get_last_log(true, "obs-studio/crashes", lastCrashLogFile);
#endif

  currentLogFile = GenerateTimeDateFilename("txt");
  dst << "obs-studio/logs/" << currentLogFile.c_str();

  BPtr<char> path(GetAppConfigPathPtr(dst.str().c_str()));

#ifdef _WIN32
  BPtr<wchar_t> wpath;
  os_utf8_to_wcs_ptr(path, 0, &wpath);
  logFile.open(wpath, ios_base::in | ios_base::out | ios_base::trunc);
#else
  logFile.open(path, ios_base::in | ios_base::out | ios_base::trunc);
#endif

  if (logFile.is_open()) {
    delete_oldest_file(false, "obs-studio/logs");
    base_set_log_handler(do_log, &logFile);
  } else {
    blog(LOG_ERROR, "Failed to open log file");
  }
}

static void get_last_log(bool has_prefix, const char *subdir_to_use, std::string &last)
{
  BPtr<char> logDir(GetAppConfigPathPtr(subdir_to_use));
  struct os_dirent *entry;
  os_dir_t *dir = os_opendir(logDir);
  uint64_t highest_ts = 0;

  if (dir) {
    while ((entry = os_readdir(dir)) != NULL) {
      if (entry->directory || *entry->d_name == '.')
        continue;

      uint64_t ts = convert_log_name(has_prefix, entry->d_name);

      if (ts > highest_ts) {
        last = entry->d_name;
        highest_ts = ts;
      }
    }

    os_closedir(dir);
  }
}

static void LogString(fstream &logFile, const char *timeString, char *str, int log_level)
{
  static mutex logfile_mutex;
  string msg;
  msg += timeString;
  msg += str;

  logfile_mutex.lock();
  logFile << msg << endl;
  logfile_mutex.unlock();

  if (!!obsLogViewer)
    QMetaObject::invokeMethod(obsLogViewer.data(), "AddLine", Qt::QueuedConnection, Q_ARG(int, log_level),
            Q_ARG(QString, QString(msg.c_str())));
}

static inline void LogStringChunk(fstream &logFile, char *str, int log_level)
{
  char *nextLine = str;
  string timeString = CurrentTimeString();
  timeString += ": ";

  while (*nextLine) {
    char *nextLine = strchr(str, '\n');
    if (!nextLine)
      break;

    if (nextLine != str && nextLine[-1] == '\r') {
      nextLine[-1] = 0;
    } else {
      nextLine[0] = 0;
    }

    LogString(logFile, timeString.c_str(), str, log_level);
    nextLine++;
    str = nextLine;
  }

  LogString(logFile, timeString.c_str(), str, log_level);
}

static inline int sum_chars(const char *str)
{
  int val = 0;
  for (; *str != 0; str++)
    val += *str;

  return val;
}

static inline bool too_many_repeated_entries(fstream &logFile, const char *msg, const char *output_str)
{
  static mutex log_mutex;
  static const char *last_msg_ptr = nullptr;
  static int last_char_sum = 0;
  static int rep_count = 0;

  int new_sum = sum_chars(output_str);

  lock_guard<mutex> guard(log_mutex);

  if (unfiltered_log) {
    return false;
  }

  if (last_msg_ptr == msg) {
    int diff = std::abs(new_sum - last_char_sum);
    if (diff < MAX_CHAR_VARIATION) {
      return (rep_count++ >= MAX_REPEATED_LINES);
    }
  }

  if (rep_count > MAX_REPEATED_LINES) {
    logFile << CurrentTimeString() << ": Last log entry repeated for "
      << to_string(rep_count - MAX_REPEATED_LINES) << " more lines" << endl;
  }

  last_msg_ptr = msg;
  last_char_sum = new_sum;
  rep_count = 0;

  return false;
}

static void do_log(int log_level, const char *msg, va_list args, void *param)
{
  fstream &logFile = *static_cast<fstream *>(param);
  char str[8192];
  
#ifndef _WIN32
  va_list args2;
  va_copy(args2, args);
#endif
  
  struct LogMessage logMessage;
  
  vsnprintf(logMessage.message, sizeof(logMessage.message), msg, args);
  logMessage.logLevel = log_level;
  
  //enqueue this and return
  queueBusy = true;
  loggingQueue.push(logMessage);
  queueBusy = false;
  
  return;
  
}

void doLogAction(LogMessage message) {
#ifdef _WIN32
  if (IsDebuggerPresent()) {
    int wNum = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
    if (wNum > 1) {
      static wstring wide_buf;
      static mutex wide_mutex;

      lock_guard<mutex> lock(wide_mutex);
      wide_buf.reserve(wNum + 1);
      wide_buf.resize(wNum - 1);
      MultiByteToWideChar(CP_UTF8, 0, str, -1, &wide_buf[0], wNum);
      wide_buf.push_back('\n');

      OutputDebugStringW(wide_buf.c_str());
    }
  }
#endif

#if !defined(_WIN32) && defined(_DEBUG)
  def_log_handler(log_level, msg, args2, nullptr);
#endif

  if (log_level <= LOG_INFO || log_verbose) {
#if !defined(_WIN32) && !defined(_DEBUG)
    def_log_handler(log_level, msg, args2, nullptr);
#endif
    if (!too_many_repeated_entries(logFile, msg, str))
      LogStringChunk(logFile, str, log_level);
  }

#if defined(_WIN32) && defined(OBS_DEBUGBREAK_ON_ERROR)
  if (log_level <= LOG_ERROR && IsDebuggerPresent())
    __debugbreak();
#endif

#ifndef _WIN32
  va_end(args2);
#endif
}


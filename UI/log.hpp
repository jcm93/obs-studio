#include "obs-app.cpp"

#define MAX_REPEATED_LINES 30
#define MAX_CHAR_VARIATION (255 * 3)

struct LogMessage {
  char[8192] message;
  int logLevel;
};

struct OBSLogger {
  fstream logFile;
  std::atomic<bool> queueHasThings = false;
  std::queue<LogMessage> messageQueue;
  std::condition_variable queueHasThingsCondition;
  std::mutex queueBusyMutex;
  std::mutex newMutex;
};

static void create_log_file(fstream &logFile);
static void LogString(fstream &logFile, const char *timeString, char *str, int log_level);
static void get_last_log(bool has_prefix, const char *subdir_to_use, std::string &last);

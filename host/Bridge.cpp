#include "Bridge.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocalSocket>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTextStream>
#include <QWindow>

#include <climits>
#include <unistd.h>

Bridge::Bridge(QLocalServer *server, QObject *parent)
    : QObject(parent), m_server(server)
{
    if (m_server)
        connect(m_server, &QLocalServer::newConnection, this, &Bridge::acceptConnection);

    // QFileSystemWatcher drops a path once the file behind it is replaced or
    // deleted. Theme switches do exactly that, so re-arm the watch on every
    // change and only then tell QML about it.
    auto rearm = [this](const QString &path) {
        if (!m_watcher.files().contains(path) && !m_watcher.directories().contains(path) && QFileInfo::exists(path))
            m_watcher.addPath(path);
        emit fileChanged(path);
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, rearm);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, rearm);
}

QString Bridge::home() const
{
    return QDir::homePath();
}

QString Bridge::runtimeDir() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    return dir.isEmpty() ? QDir::tempPath() : dir;
}

QString Bridge::configDir() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
}

QString Bridge::stateDir() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation);
}

QString Bridge::env(const QString &name) const
{
    return qEnvironmentVariable(name.toUtf8().constData());
}

int Bridge::pid() const
{
    return static_cast<int>(QCoreApplication::applicationPid());
}

QString Bridge::executable() const
{
    return QCoreApplication::applicationFilePath();
}

// Leaves without tearing Chromium down. Once the screen has been shared, its
// GPU thread has lost its EGL display (see Main.qml), and the regular
// shutdown dies on it with SIGTRAP and a core dump.
void Bridge::exitNow(int code)
{
    ::_exit(code);
}

bool Bridge::exists(const QString &path) const
{
    return QFileInfo::exists(path);
}

QString Bridge::readFile(const QString &path) const
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    return QString::fromUtf8(file.readAll());
}

bool Bridge::writeFile(const QString &path, const QString &text)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    // A watcher on the other side (the bar widget) sees a rename as a change
    // of the directory entry it already follows; QSaveFile gives it a complete
    // file every time instead of a half-written one.
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;
    file.write(text.toUtf8());
    return file.commit();
}

bool Bridge::removeFile(const QString &path)
{
    return QFile::remove(path);
}

void Bridge::watch(const QString &path)
{
    if (path.isEmpty() || !QFileInfo::exists(path))
        return;
    if (!m_watcher.files().contains(path) && !m_watcher.directories().contains(path))
        m_watcher.addPath(path);
}

// A helper gets none of this process's open files and sockets. Chromium
// leaves most of its own inheritable, and the helper that starts the next
// instance (see restart() in Main.qml) would hand it the old one's shared
// memory, GPU buffers and listening sockets, which the kernel then keeps
// for as long as the new instance runs.
void Bridge::run(const QString &program, const QStringList &arguments)
{
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.setUnixProcessParameters(QProcess::UnixProcessFlag::CloseFileDescriptors);
    process.startDetached();
}

int Bridge::runCapture(const QString &program, const QStringList &arguments)
{
    const int id = m_nextProcess++;
    auto *process = new QProcess(this);
    process->setProgram(program);
    process->setArguments(arguments);
    process->setProcessChannelMode(QProcess::SeparateChannels);
    process->setUnixProcessParameters(QProcess::UnixProcessFlag::CloseFileDescriptors);
    connect(process, &QProcess::finished, this, [this, process, id](int exitCode, QProcess::ExitStatus) {
        emit processFinished(id, exitCode, QString::fromUtf8(process->readAllStandardOutput()));
        process->deleteLater();
    });
    connect(process, &QProcess::errorOccurred, this, [this, process, id](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            emit processFinished(id, -1, QString());
            process->deleteLater();
        }
    });
    process->start();
    return id;
}

void Bridge::reply(int connection, const QString &text)
{
    QPointer<QLocalSocket> socket = m_connections.take(connection);
    if (!socket)
        return;
    socket->write(text.toUtf8());
    socket->write("\n");
    socket->flush();
    socket->disconnectFromServer();
    connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
    if (socket->state() == QLocalSocket::UnconnectedState)
        socket->deleteLater();
}

// QML sees no expose events. Hyprland suspends the surfaces of a workspace
// that is not shown, Qt treats a suspended window as unexposed, and when the
// workspace comes back the page has to be told to draw again (see Main.qml).
void Bridge::watchExposure(QWindow *window)
{
    if (!window)
        return;
    window->setProperty("omateamsExposed", window->isExposed());
    window->installEventFilter(this);
}

bool Bridge::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() == QEvent::Expose) {
        if (auto *window = qobject_cast<QWindow *>(watched)) {
            const bool was = window->property("omateamsExposed").toBool();
            const bool now = window->isExposed();
            window->setProperty("omateamsExposed", now);
            if (now != was)
                emit exposureChanged(window, now);
        }
    }
    return QObject::eventFilter(watched, event);
}

// Resident plus swapped-out memory of one process, in MiB, or -1 when it
// cannot be read. Swap counts too: on a machine short of memory the kernel
// pushes an idle page out, and RSS alone would hide how big it has grown.
int Bridge::processMemory(int pid) const
{
    if (pid <= 0)
        return -1;
    QFile file(QStringLiteral("/proc/%1/status").arg(pid));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return -1;
    qint64 kib = 0;
    bool found = false;
    const QList<QByteArray> lines = file.readAll().split('\n');
    for (const QByteArray &line : lines) {
        if (line.startsWith("VmRSS:") || line.startsWith("VmSwap:")) {
            kib += line.mid(line.indexOf(':') + 1).trimmed().split(' ').value(0).toLongLong();
            found = true;
        }
    }
    return found ? static_cast<int>(kib / 1024) : -1;
}

namespace {

// The number after `key` on the line that starts with it, as /proc/meminfo
// ("MemTotal:  16384 kB") and a cgroup's memory.stat ("active_file 4096")
// write them, or -1.
qint64 numberAfter(const QByteArray &text, const QByteArray &key)
{
    const QList<QByteArray> lines = text.split('\n');
    for (const QByteArray &line : lines) {
        if (!line.startsWith(key) || line.size() <= key.size() || line.at(key.size()) != ' ')
            continue;
        bool ok = false;
        const qint64 value = line.mid(key.size()).trimmed().split(' ').value(0).toLongLong(&ok);
        return ok ? value : -1;
    }
    return -1;
}

QByteArray contents(const QString &path)
{
    QFile file(path);
    return file.open(QIODevice::ReadOnly | QIODevice::Text) ? file.readAll() : QByteArray();
}

} // namespace

// How much memory there is for this process and how much of it is still to
// be had, in MiB: the machine's, as the kernel counts it, or what the
// tightest limit on the cgroups the process runs in leaves, whichever is
// less. Page cache counts as free in both, as it is given up when memory is
// needed. Empty when nothing can be read.
QVariantMap Bridge::memoryRoom() const
{
    qint64 total = -1;
    qint64 available = -1;

    const QByteArray meminfo = contents(QStringLiteral("/proc/meminfo"));
    const qint64 machine = numberAfter(meminfo, "MemTotal:");
    const qint64 spare = numberAfter(meminfo, "MemAvailable:");
    if (machine > 0 && spare >= 0) {
        total = machine * 1024;
        available = spare * 1024;
    }

    // "0::/user.slice/…/app.scope" names the cgroup; a limit may sit on it or
    // on any of the groups above it.
    const QString root = QStringLiteral("/sys/fs/cgroup");
    QString dir;
    const QList<QByteArray> groups = contents(QStringLiteral("/proc/self/cgroup")).split('\n');
    for (const QByteArray &line : groups) {
        if (line.startsWith("0::"))
            dir = QDir::cleanPath(root + QString::fromUtf8(line.mid(3).trimmed()));
    }
    while (dir == root || dir.startsWith(root + QLatin1Char('/'))) {
        bool limited = false;
        bool counted = false;
        const qint64 limit = contents(dir + QStringLiteral("/memory.max")).trimmed().toLongLong(&limited);
        const qint64 current = contents(dir + QStringLiteral("/memory.current")).trimmed().toLongLong(&counted);
        if (limited && counted && limit > 0) {
            const QByteArray stat = contents(dir + QStringLiteral("/memory.stat"));
            const qint64 cache = qMax<qint64>(0, numberAfter(stat, "inactive_file"))
                + qMax<qint64>(0, numberAfter(stat, "active_file"));
            const qint64 left = qMax<qint64>(0, limit - qMax<qint64>(0, current - cache));
            if (available < 0 || left < available) {
                total = limit;
                available = left;
            }
        }
        if (dir == root)
            break;
        dir = dir.left(dir.lastIndexOf(QLatin1Char('/')));
    }

    QVariantMap room;
    if (total > 0 && available >= 0) {
        const qint64 mib = 1024 * 1024;
        room.insert(QStringLiteral("total"), static_cast<int>(qMin<qint64>(total / mib, INT_MAX)));
        room.insert(QStringLiteral("available"), static_cast<int>(qMin<qint64>(available / mib, INT_MAX)));
    }
    return room;
}

void Bridge::acceptConnection()
{
    while (QLocalSocket *socket = m_server->nextPendingConnection()) {
        const int id = m_nextConnection++;
        m_connections.insert(id, socket);
        connect(socket, &QLocalSocket::readyRead, this, [this, socket, id] { readCommand(socket, id); });
        connect(socket, &QLocalSocket::disconnected, this, [this, socket, id] {
            m_connections.remove(id);
            socket->deleteLater();
        });
        if (socket->bytesAvailable() > 0)
            readCommand(socket, id);
    }
}

void Bridge::readCommand(QLocalSocket *socket, int id)
{
    if (!socket->canReadLine())
        return;
    const QString line = QString::fromUtf8(socket->readLine()).trimmed();
    if (!line.isEmpty())
        emit command(id, line);
}

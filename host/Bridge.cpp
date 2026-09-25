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

void Bridge::run(const QString &program, const QStringList &arguments)
{
    QProcess::startDetached(program, arguments);
}

int Bridge::runCapture(const QString &program, const QStringList &arguments)
{
    const int id = m_nextProcess++;
    auto *process = new QProcess(this);
    process->setProgram(program);
    process->setArguments(arguments);
    process->setProcessChannelMode(QProcess::SeparateChannels);
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
            if (now && !was)
                emit exposed(window);
        }
    }
    return QObject::eventFilter(watched, event);
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

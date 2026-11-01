package network.diwali.membership;

import org.bukkit.Bukkit;
import org.bukkit.OfflinePlayer;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.plugin.java.JavaPlugin;
import java.net.URI;
import java.net.http.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.CompletableFuture;
import java.util.regex.*;

public final class DiwaliMembership extends JavaPlugin {
    private final Set<String> managed = new HashSet<>();
    private HttpClient client;
    @Override public void onEnable() {
        saveDefaultConfig();
        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(8)).build();
        long ticks = Math.max(60, getConfig().getLong("sync-seconds",60))*20L;
        Bukkit.getScheduler().runTaskTimerAsynchronously(this, this::sync, 20L, ticks);
        getLogger().info("Diwali Membership enabled. API sync every "+(ticks/20)+" seconds.");
    }
    private void sync() {
        String base=getConfig().getString("api-url","").replaceAll("/$","");
        String secret=getConfig().getString("api-secret","");
        if(base.isBlank() || secret.equals("CHANGE_ME")) { getLogger().warning("Configure api-url and api-secret."); return; }
        try {
            HttpRequest req=HttpRequest.newBuilder(URI.create(base+"/api/plugin/active"))
                .timeout(Duration.ofSeconds(12)).header("x-plugin-secret",secret).GET().build();
            HttpResponse<String> res=client.send(req,HttpResponse.BodyHandlers.ofString());
            if(res.statusCode()!=200) { getLogger().warning("Membership API returned "+res.statusCode()+"; keeping last synced whitelist."); return; }
            Set<String> active=parseNames(res.body(), "players");
            Set<String> allManaged=parseNames(res.body(), "managed");
            Bukkit.getScheduler().runTask(this,()->apply(active, allManaged));
        } catch(Exception e) { getLogger().warning("Membership sync failed; keeping last synced whitelist: "+e.getMessage()); }
    }
    private Set<String> parseNames(String body, String key) {
        Set<String> names = new HashSet<>();
        Matcher section = Pattern.compile("\"" + key + "\"\\s*:\\s*\\[(.*?)\\]", Pattern.DOTALL).matcher(body);
        if (!section.find()) return names;
        Matcher objects = Pattern.compile("\"username\"\\s*:\\s*\"([A-Za-z0-9_]{3,16})\"").matcher(section.group(1));
        while (objects.find()) names.add(objects.group(1));
        if ("managed".equals(key)) {
            Matcher strings = Pattern.compile("\"([A-Za-z0-9_]{3,16})\"").matcher(section.group(1));
            while (strings.find()) names.add(strings.group(1));
        }
        return names;
    }
    private void apply(Set<String> active, Set<String> allManaged) {
        for (String name : active) {
            OfflinePlayer player = Bukkit.getOfflinePlayer(name);
            if (!player.isWhitelisted()) player.setWhitelisted(true);
        }
        for (String name : allManaged) {
            if (!active.contains(name)) {
                OfflinePlayer player = Bukkit.getOfflinePlayer(name);
                if (player.isWhitelisted()) player.setWhitelisted(false);
            }
        }
        managed.clear();
        managed.addAll(allManaged);
        getLogger().info("Membership whitelist sync complete. Active members: " + active.size());
    }
    @Override public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        if(!sender.hasPermission("diwali.membership.admin")) { sender.sendMessage("No permission."); return true; }
        if(args.length==1 && args[0].equalsIgnoreCase("status")) { sender.sendMessage("DiwaliMembership enabled. Managed active entries: "+managed.size()+". Sync interval: "+getConfig().getLong("sync-seconds",60)+"s"); return true; }
        sender.sendMessage("/dwm status"); return true;
    }
}

// Implments the view for one host in the left hand side bar
var HostRowView = Backbone.View.extend({
    tagName: "li",
    className: "host-row",
    template: _.template($('#host-template').html()),
    initialize: function() {
        this.model.on('change', this.render, this);
        this.model.on('destroy', this.remove, this);
    },
    events: {
        "click a.host-detail"   : "show_detail",
    },
    render: function() {
        var data = this.model.toJSON();
        data.isOk = this.model.isOk();
        data.iconClass = this.model.iconClass();
        $(this.el).html(this.template(data));
        return this;
    },
    show_detail: function() {
        var id = this.model.get("id");
        App.render_one_host(id);
    }
});
